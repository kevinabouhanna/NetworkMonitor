import CoreGraphics
import Foundation

/// Minimal assertion harness.
///
/// Neither XCTest nor swift-testing is available with Command Line Tools alone —
/// both frameworks ship inside Xcode, so `swift test` cannot run here. This
/// keeps the suite runnable today as a plain executable.
///
/// The assertion names mirror XCTest deliberately: when Xcode is installed,
/// moving these files to a real test target is a rename of `expectEqual` →
/// `XCTAssertEqual` and nothing else.
public enum Check {

    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var assertions = 0
    nonisolated(unsafe) private static var currentSuite = ""
    nonisolated(unsafe) private static var currentTest = ""
    nonisolated(unsafe) private static var testCount = 0
    nonisolated(unsafe) private static var skippedCount = 0
    nonisolated(unsafe) private static var failedTests = Set<String>()

    /// True on a CI runner unless the live tests are explicitly asked for.
    ///
    /// Tests that need real network traffic cannot get it from a sandboxed
    /// runner, so they would fail for reasons that say nothing about the code.
    /// Set `NETMON_LIVE_TESTS=1` to run them there anyway.
    public static var skipsLiveTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil && environment["NETMON_LIVE_TESTS"] != "1"
    }

    public static func suite(_ name: String, _ body: () -> Void) {
        // Only the window suites, in the VM (#675).
        if asked == .only { return }
        currentSuite = name
        print("\n\u{1B}[1m\(name)\u{1B}[0m")
        body()
    }

    // MARK: Tests that read windows (#675)

    /// Which of the tests that read a window's accessibility tree run.
    /// macOS serves no window's tree while the screen is locked, so then they
    /// can't run on this Mac, and `Scripts/test.sh` runs them in a VM instead.
    public enum Windows: String {
        case all, skip, only
    }

    /// `NETMON_WINDOWS`, when it's set: `all`, `skip` or `only`. Anything
    /// else stops the run, rather than being read as unset.
    static let asked: Windows? = {
        guard let value = ProcessInfo.processInfo.environment["NETMON_WINDOWS"], !value.isEmpty else { return nil }
        guard let asked = Windows(rawValue: value) else {
            FileHandle.standardError.write(Data("NETMON_WINDOWS=\(value): it's all, skip or only\n".utf8))
            exit(2)
        }
        return asked
    }()

    public static var screenIsLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The checkout the runner was built from, for the tests that read its
    /// files; in the VM, the copy of them `Scripts/window-tests-vm.sh` puts
    /// there (`NETMON_REPO_ROOT`).
    public static func repositoryRoot(_ filePath: String = #filePath) -> URL {
        if let root = ProcessInfo.processInfo.environment["NETMON_REPO_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Why a window suite can't run here now, if it can't: asked, or the
    /// screen locked as it starts (the lock is read again for each, as it
    /// can lock part way through a run).
    private static var skipReason: String? {
        switch asked {
        case .skip?: return "NETMON_WINDOWS=skip"
        case .all?, .only?: return nil
        case nil: return screenIsLocked ? "the screen is locked" : nil
        }
    }

    /// The window suites left out here, with why, named at the end; and
    /// whether the VM can run them.
    nonisolated(unsafe) private static var windowSkips: [(suite: String, reason: String, inVM: Bool)] = []
    /// Those the VM can't run, named at the end there.
    nonisolated(unsafe) private static var vmSkips: [String] = []

    /// A suite whose every test reads a window: its own suite, as the VM runs
    /// these alone. `notInVM` says why it can't run in the VM either, when it
    /// can't; it's then left for a run on this Mac unlocked.
    public static func windowSuite(_ name: String, notInVM: String? = nil, _ body: () -> Void) {
        currentSuite = name
        print("\n\u{1B}[1m\(name)\u{1B}[0m")
        if asked == .only, let notInVM {
            vmSkips.append("\(name): \(notInVM)")
            print("  \u{1B}[33m–\u{1B}[0m its tests \u{1B}[2m— skipped: \(notInVM)\u{1B}[0m")
        } else if asked != .only, let reason = skipReason {
            windowSkips.append((name, reason, notInVM == nil))
            print("  \u{1B}[33m–\u{1B}[0m its tests \u{1B}[2m— skipped: \(reason)\u{1B}[0m")
        } else {
            body()
        }
    }

    public static func test(_ name: String, _ body: () -> Void) {
        currentTest = name
        testCount += 1
        let before = failures.count
        body()
        let failed = failures.count > before
        let mark = failed ? "\u{1B}[31m✗\u{1B}[0m" : "\u{1B}[32m✓\u{1B}[0m"
        print("  \(mark) \(name)")
        if failed { failedTests.insert("\(currentSuite).\(name)") }
    }

    public static func skip(_ name: String, _ reason: String) {
        skippedCount += 1
        print("  \u{1B}[33m–\u{1B}[0m \(name) \u{1B}[2m— skipped: \(reason)\u{1B}[0m")
    }

    private static func fail(_ message: String, _ file: String, _ line: Int) {
        let location = "\((file as NSString).lastPathComponent):\(line)"
        failures.append("\(currentSuite) › \(currentTest)\n      \(message)\n      at \(location)")
    }

    public static func expectTrue(_ condition: Bool,
                                  _ message: String = "expected true",
                                  file: String = #file, line: Int = #line) {
        assertions += 1
        if !condition { fail(message, file, line) }
    }

    public static func expectFalse(_ condition: Bool,
                                   _ message: String = "expected false",
                                   file: String = #file, line: Int = #line) {
        assertions += 1
        if condition { fail(message, file, line) }
    }

    public static func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                                                 _ message: String = "",
                                                 file: String = #file, line: Int = #line) {
        assertions += 1
        if actual != expected {
            let detail = message.isEmpty ? "" : " — \(message)"
            fail("expected \(expected), got \(actual)\(detail)", file, line)
        }
    }

    public static func expectEqual(_ actual: Double, _ expected: Double,
                                   accuracy: Double,
                                   _ message: String = "",
                                   file: String = #file, line: Int = #line) {
        assertions += 1
        if abs(actual - expected) > accuracy {
            let detail = message.isEmpty ? "" : " — \(message)"
            fail("expected \(expected) ±\(accuracy), got \(actual)\(detail)", file, line)
        }
    }

    public static func expectNil<T>(_ value: T?,
                                    _ message: String = "expected nil",
                                    file: String = #file, line: Int = #line) {
        assertions += 1
        if let value { fail("\(message) — got \(value)", file, line) }
    }

    public static func expectNotNil<T>(_ value: T?,
                                       _ message: String = "expected non-nil",
                                       file: String = #file, line: Int = #line) {
        assertions += 1
        if value == nil { fail(message, file, line) }
    }

    // MARK: Settings of a test's own

    nonisolated(unsafe) private static var suites: [String] = []

    /// Where this run's settings live: a folder of its own under the
    /// temporary folder, never ~/Library/Preferences (#557). A suite named
    /// by a path is kept at that path. Named suites there outlived every
    /// attempt to remove them: removing a domain keeps its file, and a file
    /// deleted while the domain was open came back when the process quit.
    /// Fifty thousand had piled up.
    static let settingsFolder: URL = {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("netmon-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Settings of the test's own, empty to begin with, gone when the suite
    /// ends.
    public static func defaults(_ name: String) -> UserDefaults {
        UserDefaults(suiteName: suite(name))!
    }

    /// The same, by name, for a test that opens it again or needs its domain.
    public static func suite(_ name: String) -> String {
        let suite = settingsFolder.appendingPathComponent("\(name).\(UUID().uuidString)").path
        suites.append(suite)
        return suite
    }

    /// Empties every suite `defaults(_:)` made and deletes their folder.
    /// Returns the files in ~/Library/Preferences named after them, which
    /// should be none.
    public static func removeDefaults() -> [String] {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try? FileManager.default.removeItem(at: settingsFolder)
        let names = suites.map { URL(fileURLWithPath: $0).lastPathComponent }
        let preferences = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
        let there = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []
        suites = []
        return there.filter { file in names.contains { file.contains($0) } }
    }

    /// Prints the summary and returns the process exit code.
    public static func summarize() -> Int32 {
        print(String(repeating: "─", count: 62))
        let skipped = skippedCount == 0 ? "" : ", \(skippedCount) skipped"
        for skip in windowSkips {
            let locked = skip.reason == "the screen is locked"
            print("\u{1B}[33mNot run here, as \(skip.reason):\u{1B}[0m \(skip.suite), whose tests read windows."
                  + (!locked ? "" : skip.inVM ? " `make test` runs them in a VM (#675)." : " They run once this Mac is unlocked."))
        }
        // Tells Scripts/test.sh to run them in the VM, when the lock skipped them.
        if windowSkips.contains(where: { $0.inVM && $0.reason == "the screen is locked" }),
           let marker = ProcessInfo.processInfo.environment["NETMON_WINDOWS_SKIPPED"] {
            FileManager.default.createFile(atPath: marker, contents: Data("the screen is locked".utf8))
        }
        for skip in vmSkips {
            print("\u{1B}[33mNot run in the VM:\u{1B}[0m \(skip). They run whenever this Mac is unlocked.")
        }
        if failures.isEmpty {
            print("\u{1B}[32mAll \(testCount) tests passed\u{1B}[0m "
                  + "(\(assertions) assertions\(skipped))")
            return 0
        }
        print("\u{1B}[31m\(failedTests.count) of \(testCount) tests failed\u{1B}[0m "
              + "(\(assertions) assertions, \(failures.count) failures\(skipped))\n")
        for failure in failures { print("  \u{1B}[31m✗\u{1B}[0m \(failure)\n") }
        return 1
    }
}

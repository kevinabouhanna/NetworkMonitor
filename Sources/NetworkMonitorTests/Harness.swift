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
        currentSuite = name
        print("\n\u{1B}[1m\(name)\u{1B}[0m")
        body()
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

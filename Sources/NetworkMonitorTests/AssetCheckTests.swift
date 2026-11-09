import Foundation

/// `make asset-check` (Scripts/site-shots.swift `coverage`): an asset made by
/// hand says which app version it was made from, and fails when that's older
/// than the record of a window it shows (#421). The tool is a script, so it's
/// built here and run on a small site made up for each case.
func runAssetCheckTests() {
    Check.suite("Asset check: what each asset was made from (#421)") {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-check-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let tool = work.appendingPathComponent("site-shots")
        let built = shell("/usr/bin/xcrun", ["swiftc", "-parse-as-library",
                                             root.appendingPathComponent("Scripts/site-shots.swift").path,
                                             root.appendingPathComponent("Sources/NetworkMonitorCore/AccessibilityAudit.swift").path,
                                             "-o", tool.path])
        guard built.status == 0 else {
            Check.test("site-shots builds") { Check.expectEqual(built.status, 0, built.output) }
            return
        }

        /// A site whose page shows one video of the popover, listed with
        /// `entry`'s fields, and `versions` as its records' versions.
        func coverage(_ entry: String, versions: [String: String], madeRecord: Bool = false) -> (status: Int32, output: String) {
            let site = work.appendingPathComponent("site-\(UUID().uuidString)")
            let repo = work.appendingPathComponent("repo-\(UUID().uuidString)")
            let trees = site.appendingPathComponent("shots/trees")
            try? FileManager.default.createDirectory(at: trees, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: site.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try? Data().write(to: site.appendingPathComponent("assets/live.mp4"))
            try? #"<video src="assets/live.mp4"></video>"#.write(to: site.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
            try? """
            {"app": "/Applications/NetworkMonitor.app", "bundle": "x",
             "shots": [{"name": "popover", "open": [], "window": "AXPopover"}],
             "assets": [{"file": "assets/live.mp4", "shows": ["popover"]\(entry)}]}
            """.write(to: site.appendingPathComponent("shots/shots.json"), atomically: true, encoding: .utf8)
            try? "AXPopover\n".write(to: trees.appendingPathComponent("popover.txt"), atomically: true, encoding: .utf8)
            if madeRecord {
                try? "AXPopover\n".write(to: trees.appendingPathComponent("popover.made.txt"), atomically: true, encoding: .utf8)
            }
            try? JSONEncoder().encode(versions).write(to: trees.appendingPathComponent("versions.json"))
            return shell(tool.path, ["coverage", "--site", site.path, "--repo", repo.path])
        }

        Check.test("an asset made from today's window passes") {
            let r = coverage(#", "made": "1.28.1""#, versions: ["popover.txt": "1.28.1"])
            Check.expectEqual(r.status, 0, r.output)
        }

        Check.test("one made from an older window fails, though the window hasn't changed since it was listed") {
            let r = coverage(#", "made": "1.4.1""#, versions: ["popover.txt": "1.26.7"])
            Check.expectEqual(r.status, 1, r.output)
            Check.expectTrue(r.output.contains("made from 1.4.1") && r.output.contains("popover (1.26.7)"), r.output)
        }

        Check.test("a new entry must say what it was made from") {
            let r = coverage("", versions: ["popover.txt": "1.28.1"])
            Check.expectEqual(r.status, 1, r.output)
            Check.expectTrue(r.output.contains("needs `made`"), r.output)
            let word = coverage(#", "made": "today""#, versions: ["popover.txt": "1.28.1"])
            Check.expectEqual(word.status, 1, word.output)
        }

        Check.test("versions compare as numbers: 1.9 is before 1.10") {
            Check.expectEqual(coverage(#", "made": "1.10.0""#, versions: ["popover.txt": "1.9.9"]).status, 0)
            Check.expectEqual(coverage(#", "made": "1.9.9""#, versions: ["popover.txt": "1.10"]).status, 1)
            Check.expectEqual(coverage(#", "made": "1.28""#, versions: ["popover.txt": "1.28.0"]).status, 0)
        }

        Check.test("it's checked against the tree it was last remade from, not the window's latest picture") {
            // The window changed and its picture was retaken (popover.txt), but
            // what's made by hand is remade later, from popover.made.txt.
            let r = coverage(#", "made": "1.26.7""#,
                             versions: ["popover.txt": "1.28.1", "popover.made.txt": "1.26.7"], madeRecord: true)
            Check.expectEqual(r.status, 0, r.output)
        }

        Check.test("one waiting on an issue is named without failing") {
            let r = coverage(##", "made": "1.4.1", "stale": "#420""##, versions: ["popover.txt": "1.26.7"])
            Check.expectEqual(r.status, 0, r.output)
            Check.expectTrue(r.output.contains("waits on #420"), r.output)
        }

        Check.test("once it's remade, `stale` has to come out") {
            let r = coverage(##", "made": "1.28.1", "stale": "#420""##, versions: ["popover.txt": "1.28.1"])
            Check.expectEqual(r.status, 1, r.output)
            Check.expectTrue(r.output.contains("take out `stale`"), r.output)
        }
    }
}

/// Runs a program and returns its exit status and what it printed.
private func shell(_ program: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: program)
    task.arguments = arguments
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do { try task.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

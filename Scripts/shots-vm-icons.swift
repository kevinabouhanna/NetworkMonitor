// Stand-ins for this Mac's apps, for the website's pictures taken in a VM
// (#561). The VM has none of this Mac's apps, so the rows that name them would
// show a blank page where this Mac shows their icon, and the Network section
// wouldn't find the apps whose updates it pauses. For each path on stdin that's
// here, this writes under <out> a stand-in at the same path, with nothing that
// runs:
// - an app: its Info.plist, a program that does nothing in its place (<exec>:
//   without one, macOS marks the app as one that can't open), its icon (the asset catalog and .icns it names,
//   so the VM draws it as this Mac does), and what UpdaterScan.inspect looks
//   for: app-update.yml, Squirrel.framework and Sparkle.framework as empty
//   folders, and anything named like an updater where it looks, empty;
// - a program that isn't a bundle: an empty file with the same permissions.
// It prints the path of each one it made. Scripts/shots-vm-prepare.sh runs it;
// Scripts/shots-vm-setup.sh puts each one in place in the VM.
//
// Usage: … | swift Scripts/shots-vm-icons.swift <out> <exec>

import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let exec = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
var made = 0

func copy(_ from: URL, _ to: URL) {
    try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.copyItem(at: from, to: to)
}

/// Named like an updater, as UpdaterScan.looksLikeUpdater has it.
func looksLikeUpdater(_ name: String) -> Bool {
    let lowered = name.lowercased()
    return lowered.contains("updat") || lowered.contains("shipit")
}

func standIn(app: URL, at stub: URL) {
    let contents = app.appendingPathComponent("Contents")
    let into = stub.appendingPathComponent("Contents")
    copy(contents.appendingPathComponent("Info.plist"), into.appendingPathComponent("Info.plist"))
    let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
    if let name = info["CFBundleExecutable"] as? String {
        copy(exec, into.appendingPathComponent("MacOS/\(name)"))
    }
    // The icon, as this Mac draws it.
    var icons = ["Resources/Assets.car"]
    if let file = info["CFBundleIconFile"] as? String {
        icons += ["Resources/\(file)", "Resources/\(file).icns"]
    }
    for rel in icons where fm.fileExists(atPath: contents.appendingPathComponent(rel).path) {
        copy(contents.appendingPathComponent(rel), into.appendingPathComponent(rel))
    }
    // What the updater scan reads, with nothing in it.
    copy(contents.appendingPathComponent("Resources/app-update.yml"), into.appendingPathComponent("Resources/app-update.yml"))
    for framework in ["Squirrel", "Sparkle"] {
        let rel = "Frameworks/\(framework).framework"
        if fm.fileExists(atPath: contents.appendingPathComponent(rel).path) {
            try? fm.createDirectory(at: into.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
    }
    for location in ["MacOS", "Helpers", "Frameworks", "Resources",
                     "Library/LaunchServices", "Library/LaunchAgents", "Library/LaunchDaemons"] {
        let folder = contents.appendingPathComponent(location)
        for entry in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where looksLikeUpdater(entry) {
            let path = folder.appendingPathComponent(entry)
            let target = into.appendingPathComponent(location).appendingPathComponent(entry)
            var isFolder: ObjCBool = false
            fm.fileExists(atPath: path.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if entry.hasSuffix(".plist") {
                copy(path, target)
            } else {
                try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let mode = (try? fm.attributesOfItem(atPath: path.path)[.posixPermissions]) as? NSNumber ?? 0o755
                fm.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: mode])
            }
        }
    }
}

var seen = Set<String>()
while let line = readLine() {
    let path = line.trimmingCharacters(in: .whitespaces)
    // The system's own apps are in the VM too.
    guard !path.isEmpty, !path.hasPrefix("/System/"), seen.insert(path).inserted, fm.fileExists(atPath: path) else { continue }
    let stub = out.appendingPathComponent(String(path.dropFirst()))
    var isFolder: ObjCBool = false
    fm.fileExists(atPath: path, isDirectory: &isFolder)
    if isFolder.boolValue {
        guard fm.fileExists(atPath: path + "/Contents/Info.plist") else { continue }
        standIn(app: URL(fileURLWithPath: path), at: stub)
    } else {
        try? fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mode = (try? fm.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber ?? 0o755
        fm.createFile(atPath: stub.path, contents: nil, attributes: [.posixPermissions: mode])
    }
    print(path)
    made += 1
}
FileHandle.standardError.write("shots-vm-icons: \(made) stand-ins\n".data(using: .utf8)!)

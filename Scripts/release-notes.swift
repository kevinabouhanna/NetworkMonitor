// What the update window shows (#163): every recent version's What's new,
// newest first, as HTML, so each reader sees the versions they're missing.
//
// Each version is a <div data-sparkle-version="BUILD">. Sparkle 2.5 and later
// gives the one matching the installed build the class
// sparkle-installed-version, and the CSS below hides it and everything older.
// That runs in the copy already installed, so it works from 1.15 on, which
// Markdown notes, trimmed by the app's own code, wouldn't.
//
// Usage: swift Scripts/release-notes.swift <version> <build>
//
// Reads ReleaseNotes/<version>.md for each version up to <version>. An earlier
// version's build is its tag's commit count, which is what bundle.sh stamps.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let currentBuild = Int(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: release-notes.swift <version> <build>\n".utf8))
    exit(64)
}
let current = arguments[1]
let repository = "https://github.com/kevinabouhanna/NetworkMonitor"
/// Enough for anyone who updates now and then; older readers see these ten.
let shown = 10

func parts(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
func isOlder(_ a: String, than b: String) -> Bool {
    let (x, y) = (parts(a), parts(b))
    for index in 0..<max(x.count, y.count) {
        let (p, q) = (index < x.count ? x[index] : 0, index < y.count ? y[index] : 0)
        if p != q { return p < q }
    }
    return false
}

func commitCount(atTag tag: String) -> Int? {
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["rev-list", "--count", tag]
    let output = Pipe()
    git.standardOutput = output
    git.standardError = FileHandle.nullDevice
    guard (try? git.run()) != nil else { return nil }
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    git.waitUntilExit()
    return git.terminationStatus == 0 ? Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
}

// MARK: Markdown, the little the notes use

func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func replacing(_ pattern: String, in text: String, with template: String) -> String {
    let expression = try! NSRegularExpression(pattern: pattern)
    return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: template)
}

/// Code spans first, set aside so nothing inside them is read as emphasis.
func inline(_ markdown: String) -> String {
    var spans: [String] = []
    var text = ""
    let pieces = markdown.components(separatedBy: "`")
    for (index, piece) in pieces.enumerated() {
        if index % 2 == 1 && index < pieces.count - 1 {
            spans.append("<code>\(escaped(piece))</code>")
            text += "\u{1}\(spans.count - 1)\u{2}"
        } else {
            text += (index % 2 == 1 ? "`" : "") + escaped(piece)
        }
    }
    text = replacing(#"\[([^\]]+)\]\(([^)\s]+)\)"#, in: text, with: "<a href=\"$2\">$1</a>")
    text = replacing(#"\*\*(.+?)\*\*"#, in: text, with: "<b>$1</b>")
    text = replacing(#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, in: text, with: "<i>$1</i>")
    text = replacing(#"(?<![\w/&])#(\d+)\b"#, in: text, with: "<a href=\"\(repository)/issues/$1\">#$1</a>")
    for (index, span) in spans.enumerated() {
        text = text.replacingOccurrences(of: "\u{1}\(index)\u{2}", with: span)
    }
    return text
}

/// Bullets, with indented lines continuing one, and paragraphs.
func html(_ markdown: String) -> String {
    var blocks: [String] = []
    var items: [String] = []
    var paragraph: [String] = []
    func flush() {
        if !items.isEmpty { blocks.append("<ul>" + items.map { "<li>\(inline($0))</li>" }.joined() + "</ul>") }
        if !paragraph.isEmpty { blocks.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
        items = []
        paragraph = []
    }
    for line in markdown.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flush()
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            if !paragraph.isEmpty { flush() }
            items.append(String(trimmed.dropFirst(2)))
        } else if !items.isEmpty && line.first == " " {
            items[items.count - 1] += " " + trimmed
        } else {
            if !items.isEmpty { flush() }
            paragraph.append(trimmed)
        }
    }
    flush()
    return blocks.joined(separator: "\n")
}

// MARK: The versions

let directory = URL(fileURLWithPath: "ReleaseNotes")
let versions = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    .filter { $0.hasSuffix(".md") }
    .map { String($0.dropLast(3)) }
    .filter { $0.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil }
    .filter { !isOlder(current, than: $0) }
    .sorted { isOlder($1, than: $0) }

guard versions.first == current else {
    FileHandle.standardError.write(Data("error: ReleaseNotes/\(current).md is missing\n".utf8))
    exit(1)
}

var sections: [String] = []
for version in versions {
    guard sections.count < shown else { break }
    // A file for a version that was never tagged has no build to match.
    guard let build = version == current ? currentBuild : commitCount(atTag: "v\(version)") else { continue }
    let notes = (try? String(contentsOf: directory.appendingPathComponent("\(version).md"), encoding: .utf8)) ?? ""
    sections.append("""
        <div data-sparkle-version="\(build)">
        <h3>Version \(version)</h3>
        \(html(notes))
        </div>
        """)
}

print("""
    <style>
    :root { color-scheme: light dark; }
    body { font: 13px/1.4 -apple-system, sans-serif; margin: 2px 6px; }
    h3 { font-size: 13px; font-weight: 600; margin: 14px 0 2px; opacity: 0.6; }
    div:first-of-type h3 { margin-top: 0; }
    ul { margin: 0; padding-left: 18px; }
    li { margin: 4px 0; }
    p { margin: 4px 0; }
    code { font: 12px ui-monospace, monospace; }
    a { color: LinkText; }
    div.sparkle-installed-version, div.sparkle-installed-version ~ div { display: none; }
    </style>
    """)
print(sections.joined(separator: "\n"))

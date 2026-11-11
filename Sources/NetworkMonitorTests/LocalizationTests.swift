import Foundation
import NetworkMonitorCore

/// The app in the Mac's language, or the one chosen (#433): which language is
/// picked, how text is filled in, and that every piece of text the interface
/// shows goes through `L("…")` and is in every language's table.
func runLocalizationTests() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let tables = root.appendingPathComponent("Resources/Localization")
    // The suite runs outside the app, so it reads the checkout's tables.
    Localization.shared.useTables(in: tables)
    Localization.shared.showForThisRun(Localization.source)

    Check.suite("Localization") {
        let both = ["en", "zh-Hans"]

        Check.test("the Mac's first language with a table wins, English otherwise") {
            Check.expectEqual(Localization.match(["zh-Hans-CN"], available: both), "zh-Hans")
            Check.expectEqual(Localization.match(["zh-CN"], available: both), "zh-Hans")
            Check.expectEqual(Localization.match(["fr-FR", "zh-Hans-CN", "en-US"], available: both), "zh-Hans")
            Check.expectEqual(Localization.match(["en-GB", "zh-Hans"], available: both), "en")
            Check.expectEqual(Localization.match(["fr-FR"], available: both), "en")
            Check.expectEqual(Localization.match([], available: both), "en")
        }

        Check.test("a language chosen for the app wins over the Mac's, and System goes back to it") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            for code in both {
                let lproj = dir.appendingPathComponent("\(code).lproj")
                try? FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
                try? "\"Settings\" = \"设置\";".write(to: lproj.appendingPathComponent("Localizable.strings"),
                                                     atomically: true, encoding: .utf8)
            }
            let suite = Check.suite("l10n")
            let defaults = UserDefaults(suiteName: suite)!
            let mac = ["zh-Hans-CN", "en-US"]
            let localization = Localization(defaults: defaults, domain: suite, arguments: [:],
                                            systemLanguages: { mac }, directory: dir)
            Check.expectEqual(localization.available, both)
            Check.expectEqual(localization.code, "zh-Hans", "follows the Mac")
            Check.expectNil(localization.choice)
            Check.expectEqual(localization.text("Settings"), "设置")
            Check.expectEqual(localization.text("Quit"), "Quit", "a string a table lacks shows in English")

            localization.choose("en")
            Check.expectEqual(localization.code, "en")
            Check.expectEqual(localization.choice, "en")
            Check.expectEqual(localization.text("Settings"), "Settings")
            Check.expectEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"],
                              "kept where macOS's own per-app language setting keeps it")

            localization.choose(nil)
            Check.expectNil(localization.choice)
            Check.expectEqual(localization.code, "zh-Hans")

            let launched = Localization(defaults: defaults, domain: suite, arguments: ["language": "en"],
                                        systemLanguages: { mac }, directory: dir)
            Check.expectEqual(launched.code, "en", "-language picks one for the run")
        }

        Check.test("placeholders are filled in order, or by number") {
            Check.expectEqual(Localization.fill("Apps paused (%@ of %@)", ["2", "5"]), "Apps paused (2 of 5)")
            Check.expectEqual(Localization.fill("%2$@ 中的 %1$@", ["2", "5"]), "5 中的 2")
            Check.expectEqual(Localization.fill("%@%% identified", ["80"]), "80% identified")
            Check.expectEqual(Localization.fill("%@ and %@", ["a"]), "a and ", "a missing argument is empty")
            Check.expectEqual(Localization.placeholders(in: "%@ of %@"), ["%1$@", "%2$@"])
            Check.expectEqual(Localization.placeholders(in: "%2$@ 中的 %1$@"), ["%1$@", "%2$@"])
        }

        // MARK: The sources against the tables

        let sources = SourceText.load(root)

        Check.test("every L() is given one plain literal, the key the tables use") {
            for problem in sources.badCalls { Check.expectTrue(false, problem) }
        }

        Check.test("no English text reaches the interface without L()") {
            for problem in sources.bareText { Check.expectTrue(false, problem) }
        }

        let keys = sources.keys
        Check.test("the sources have text to translate") {
            Check.expectTrue(keys.count > 100, "found only \(keys.count) keys")
        }

        // Each language's table against these keys, its placeholders and its
        // glossary: `lang-kit strings`, the next step of `make test` (#558).
    }
}

/// The app's Swift sources, read for their `L("…")` keys and for text that
/// skipped it.
struct SourceText {
    var keys: Set<String> = []
    var badCalls: [String] = []
    var bareText: [String] = []

    /// Where text reaches the screen as a literal. It finds the usual ways in;
    /// others (`return "…"` from a label) rely on review and the tables.
    static let bare = try! NSRegularExpression(pattern: #"""
        (?x)
          \b(?:Text|Button|Label|Toggle|Picker|Link|Menu|GroupBox|LabeledContent|TextField|SecureField|
               Stepper|DisclosureGroup|ColorPicker|Section|ProgressView)\(\s*"((?:[^"\\]|\\.)*)"
        | \.(?:help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle)\(\s*"((?:[^"\\]|\\.)*)"
        | \b(?:withTitle|title|label|message|prompt|placeholder|toolTip|help|accessibilityDescription):\s*"((?:[^"\\]|\\.)*)"
        | \.(?:title|label|toolTip|messageText|informativeText|placeholderString|paletteLabel)\s*=\s*"((?:[^"\\]|\\.)*)"
        | \bset(?:Label|ToolTip)\(\s*"((?:[^"\\]|\\.)*)"
        """#)
    static let call = try! NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)"\s*([,)+])"#)
    static let anyCall = try! NSRegularExpression(pattern: #"(?<![\w.])L\("#)
    static let word = try! NSRegularExpression(pattern: "[A-Za-z]{2,}")

    static func load(_ root: URL) -> SourceText {
        var result = SourceText()
        for folder in ["Sources/NetworkMonitorCore", "Sources/NetworkMonitor"] {
            let dir = root.appendingPathComponent(folder)
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".swift") }.sorted()
            for file in files where file != "Localization.swift" && file != "AccessibilityAudit.swift" {
                guard let text = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                else { continue }
                for (number, line) in text.components(separatedBy: "\n").enumerated() {
                    result.read(line, at: "\(file):\(number + 1)")
                }
            }
        }
        return result
    }

    private mutating func read(_ line: String, at place: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { return }
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)

        let calls = Self.call.matches(in: line, range: all)
        for match in calls {
            let literal = ns.substring(with: match.range(at: 1))
            if ns.substring(with: match.range(at: 2)) == "+" || literal.contains("\\(") {
                badCalls.append("\(place): L() needs one plain literal: \(trimmed)")
            } else {
                keys.insert(Self.unescape(literal))
            }
        }
        if Self.anyCall.numberOfMatches(in: line, range: all) > calls.count {
            badCalls.append("\(place): L() needs a string literal: \(trimmed)")
        }

        // Text that looks shown but isn't, marked `// untranslated: why`.
        guard !line.contains("// untranslated") else { return }
        for match in Self.bare.matches(in: line, range: all) {
            for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                // Interpolated parts aren't words to translate.
                let literal = ns.substring(with: match.range(at: group))
                    .replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
                if Self.word.firstMatch(in: literal, range: NSRange(location: 0, length: (literal as NSString).length)) != nil {
                    bareText.append("\(place): \"\(literal)\" isn't in L()")
                }
            }
        }
    }

    /// A Swift literal's text, as the tables hold it.
    static func unescape(_ literal: String) -> String {
        var out = ""
        var chars = literal.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let e = chars.next() else { out.append(c); continue }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "0": out.append("\0")
            case "u":
                var hex = ""
                _ = chars.next()   // {
                while let h = chars.next(), h != "}" { hex.append(h) }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { out.append(Character(scalar)) }
            default: out.append(e)   // \" \\ \'
            }
        }
        return out
    }
}

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
            let suite = "l10n-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
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

        for code in Localization.shared.available where code != Localization.source {
            let table = Localization.table(for: code, in: tables)
            Check.test("\(code): its table has every piece of text, with the same placeholders") {
                Check.expectFalse(table.isEmpty, "\(code).lproj/Localizable.strings didn't load")
                let missing = keys.subtracting(table.keys).sorted()
                Check.expectTrue(missing.isEmpty,
                                 "\(missing.count) missing, such as: \(missing.prefix(5).joined(separator: " | "))")
                for (english, translated) in table where Localization.placeholders(in: english)
                    != Localization.placeholders(in: translated) {
                    Check.expectTrue(false, "placeholders differ: \"\(english)\" → \"\(translated)\"")
                }
            }
            Check.test("\(code): its table has nothing the app no longer says") {
                let stale = Set(table.keys).subtracting(keys).sorted()
                Check.expectTrue(stale.isEmpty,
                                 "\(stale.count) unused, such as: \(stale.prefix(5).joined(separator: " | "))")
            }
            Check.test("\(code): its table names things as its glossary does") {
                let url = tables.appendingPathComponent("\(code).lproj/Glossary.json")
                guard let data = try? Data(contentsOf: url) else {
                    return Check.expectTrue(false, "\(code).lproj has no Glossary.json; write it first (docs/development.md#adding-a-language)")
                }
                do {
                    let glossary = try JSONDecoder().decode(Glossary.self, from: data)
                    Check.expectEqual(glossary.language, code)
                    for problem in glossary.problems(table: table, keys: keys) { Check.expectTrue(false, problem) }
                } catch {
                    Check.expectTrue(false, "\(code).lproj/Glossary.json doesn't read: \(error)")
                }
            }
        }
    }
}

/// A language's words for the app's windows, sections, features and settings
/// (#434), in `<code>.lproj/Glossary.json`. Written before anything is
/// translated, and shared by the app's table, the docs, the README, the wiki
/// and the website, so they all name things the same way. The test holds the
/// app's table to it; the docs and the site follow it by hand.
struct Glossary: Decodable {
    struct Term: Decodable {
        /// The English, as the app writes it.
        var en: String
        /// This language's word for it.
        var text: String
        /// Also in every piece of the app's text that says the English, as a
        /// whole word in any case: `Ad blocking is off` holds `广告拦截` too.
        var everywhere: Bool?
        /// `docs` for a name only the docs and the website use.
        var `where`: String?
        var note: String?
    }
    struct Avoid: Decodable {
        var text: String
        var why: String
    }
    var language: String
    var terms: [Term]
    /// Words no translation may use.
    var avoid: [Avoid]?

    /// Where the table says something else, one line each.
    func problems(table: [String: String], keys: Set<String>) -> [String] {
        var problems: [String] = []
        for term in terms where term.where != "docs" {
            var said = false
            if keys.contains(term.en) {
                said = true
                if table[term.en] != term.text {
                    problems.append("\"\(term.en)\" is \"\(table[term.en] ?? "")\", but the glossary says \"\(term.text)\"")
                }
            }
            if term.everywhere == true {
                let word = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: term.en) + "\\b",
                                                    options: .caseInsensitive)
                for key in keys.sorted() where word.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil {
                    said = true
                    if let translated = table[key], !translated.contains(term.text) {
                        problems.append("\"\(key)\" → \"\(translated)\" doesn't say \"\(term.text)\" for \"\(term.en)\"")
                    }
                }
            }
            if !said {
                problems.append("the app no longer says \"\(term.en)\": change the glossary's term, or mark it \"where\": \"docs\"")
            }
        }
        for avoid in avoid ?? [] {
            for (english, translated) in table.sorted(by: { $0.key < $1.key }) where translated.contains(avoid.text) {
                problems.append("\"\(english)\" → \"\(translated)\" uses \"\(avoid.text)\": \(avoid.why)")
            }
        }
        return problems
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

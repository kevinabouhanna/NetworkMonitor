import AppKit
import Combine
import Foundation
import SwiftUI

/// The app's words, in the Mac's language or the one chosen in Settings (#433).
///
/// **English is the source.** Every piece of text is written in English where it
/// is used, wrapped in `L("…")`, and that English is its key in every other
/// language's table: `Resources/Localization/<code>.lproj/Localizable.strings`,
/// which `bundle.sh` copies into the app. Adding a language is adding its folder;
/// nothing in the code lists them. A string a table doesn't have yet shows in
/// English.
///
/// **Which language.** The first of the Mac's preferred languages the app has a
/// table for (System Settings › General › Language & Region), English otherwise.
/// A language chosen in Settings, or for this app alone in System Settings'
/// *Applications* list, wins over that: both are the same setting, the app's own
/// `AppleLanguages`, so the two never disagree, and macOS's own words in the app
/// (Sparkle's update window, a text field's menu) follow it from the next launch.
/// `-language zh-Hans` as a launch argument picks one for that run only, for the
/// website's pictures and for checking a window.
///
/// The change applies at once: each window's SwiftUI content is rebuilt through
/// `localizedRoot()`, and what AppKit shows (window titles, toolbar labels, the
/// menus) is set again on `Localization.didChange`.
public final class Localization: ObservableObject {

    public static let shared = Localization()

    /// Posted on the main queue after the language changes.
    public static let didChange = Notification.Name("NetworkMonitor.languageDidChange")

    /// The language every key is written in.
    public static let source = "en"

    /// Where the app's own choice is kept. macOS's per-app language setting
    /// writes the same key, which is what makes the two one setting.
    static let choiceKey = "AppleLanguages"

    /// The language the app's words are in now, as its table's code (`en`,
    /// `zh-Hans`).
    @Published public private(set) var code: String = Localization.source

    /// For numbers and dates: the language shown, with the Mac's region.
    public var locale: Locale {
        let region = Locale.current.region?.identifier
        return Locale(identifier: region.map { "\(code)_\($0)" } ?? code)
    }

    /// Every language with a table, the source first.
    public private(set) var available: [String] = [Localization.source]

    private let defaults: UserDefaults
    private let domain: String?
    /// A language shown for this run only: `-language`, or the tests'.
    private var override: String?
    private let systemLanguages: () -> [String]
    private var directory: URL?
    private let lock = NSLock()
    private var table: [String: String] = [:]

    /// - Parameters:
    ///   - defaults: where the choice is kept.
    ///   - domain: the name of `defaults`' own domain, to tell a choice made for
    ///     this app from the Mac's languages, which `defaults` also reads.
    ///   - arguments: the launch arguments, for `-language`.
    ///   - systemLanguages: the Mac's preferred languages, read fresh, so going
    ///     back to System follows the Mac's list as it is now.
    ///   - directory: the folder holding the `<code>.lproj` tables.
    public init(defaults: UserDefaults = .standard,
                domain: String? = Bundle.main.bundleIdentifier,
                arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain),
                systemLanguages: @escaping () -> [String] = Localization.macLanguages,
                directory: URL? = Bundle.main.resourceURL) {
        self.defaults = defaults
        self.domain = domain
        self.override = arguments["language"] as? String
        self.systemLanguages = systemLanguages
        useTables(in: directory)
    }

    /// The Mac's preferred languages, from the global domain rather than
    /// `Locale.preferredLanguages`, which includes the app's own choice and
    /// keeps what it read at launch.
    public static func macLanguages() -> [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[choiceKey] as? [String]
            ?? Locale.preferredLanguages
    }

    /// Reads the tables from `directory`, and picks the language again.
    /// The tests point it at `Resources/Localization` in the checkout.
    public func useTables(in directory: URL?) {
        self.directory = directory
        let found = (try? FileManager.default.contentsOfDirectory(atPath: directory?.path ?? "")) ?? []
        let codes = found.filter { $0.hasSuffix(".lproj") && $0 != "Base.lproj" }
            .map { String($0.dropLast(".lproj".count)) }
            .filter { $0 != Self.source }
            .sorted()
        available = [Self.source] + codes
        apply(resolve())
    }

    // MARK: Choosing

    /// The language chosen for this app, or nil to follow the Mac.
    public var choice: String? {
        let own = domain.flatMap { defaults.persistentDomain(forName: $0) }?[Self.choiceKey] as? [String]
        guard let own, !own.isEmpty else { return nil }
        return Self.match(own, available: available)
    }

    /// Chooses a language for this app, or nil to follow the Mac again.
    public func choose(_ code: String?) {
        // Choosing the language already shown changes no words, but the
        // choice itself still has to show.
        objectWillChange.send()
        if let code {
            defaults.set([code], forKey: Self.choiceKey)
        } else {
            defaults.removeObject(forKey: Self.choiceKey)
        }
        apply(resolve())
    }

    /// Shows `code` for this run only, saving nothing, as `-language` does;
    /// nil goes back to the saved choice or the Mac's. For the tests, which
    /// check every window in every language.
    public func showForThisRun(_ code: String?) {
        override = code
        apply(resolve())
    }

    /// The language to show: this run's, the one chosen, or the Mac's.
    func resolve() -> String {
        if let override {
            return Self.match([override], available: available)
        }
        if let choice { return choice }
        return Self.match(systemLanguages(), available: available)
    }

    /// The first of `preferences` that one of `available` serves, the way macOS
    /// picks a localization: `zh-CN` and `zh-Hans-CN` find `zh-Hans`, a language
    /// with no table is passed over, and nothing found is English.
    public static func match(_ preferences: [String], available: [String]) -> String {
        Bundle.preferredLocalizations(from: available, forPreferences: preferences).first ?? source
    }

    /// The name of a language in that language, so it can be found whichever
    /// one is showing: English, 简体中文.
    public static func nativeName(of code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized(with: Locale(identifier: code))
            ?? code
    }

    private func apply(_ code: String) {
        let table = Self.table(for: code, in: directory)
        lock.lock()
        self.table = table
        lock.unlock()
        guard code != self.code else { return }
        self.code = code
        let post = { NotificationCenter.default.post(name: Self.didChange, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    /// A language's table: English text to its translation.
    public static func table(for code: String, in directory: URL?) -> [String: String] {
        guard code != source,
              let url = directory?.appendingPathComponent("\(code).lproj/Localizable.strings"),
              let table = NSDictionary(contentsOf: url) as? [String: String]
        else { return [:] }
        return table
    }

    // MARK: Looking up

    /// `english` in the language shown, with each `%@` (or `%1$@`, `%2$@` where a
    /// language puts them in another order) replaced by the next of `arguments`.
    public func text(_ english: String, _ arguments: [String] = []) -> String {
        lock.lock()
        let translated = table[english]
        lock.unlock()
        let text = translated.flatMap { $0.isEmpty ? nil : $0 } ?? english
        return arguments.isEmpty ? text : Self.fill(text, arguments)
    }

    /// Replaces `%@`, `%n$@` and `%%`. Only `%@`: callers format numbers
    /// themselves, so a table can't ask for a type the caller didn't pass.
    public static func fill(_ text: String, _ arguments: [String]) -> String {
        var result = ""
        var next = 0
        var rest = Substring(text)
        while let percent = rest.firstIndex(of: "%") {
            result += rest[..<percent]
            let after = rest[rest.index(after: percent)...]
            if after.hasPrefix("%") {
                result += "%"
                rest = after.dropFirst()
            } else if after.hasPrefix("@") {
                result += next < arguments.count ? arguments[next] : ""
                next += 1
                rest = after.dropFirst()
            } else if let dollar = after.firstIndex(of: "$"),
                      let position = Int(after[..<dollar]),
                      after[after.index(after: dollar)...].hasPrefix("@") {
                result += position >= 1 && position <= arguments.count ? arguments[position - 1] : ""
                rest = after[after.index(dollar, offsetBy: 2)...]
            } else {
                result += "%"
                rest = after
            }
        }
        return result + rest
    }

    /// The placeholders in `text`, to check a translation has the ones its
    /// English has.
    public static func placeholders(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?@"#)
        let ns = text as NSString
        var sequential = 0
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            let token = ns.substring(with: match.range)
            if token == "%@" { sequential += 1; return "%\(sequential)$@" }
            return token
        }.sorted()
    }
}

/// `english` in the language the app is showing (see `Localization`).
///
/// Always a single string literal, never built from pieces or interpolated:
/// the literal is the key the tables are checked against.
public func L(_ english: String) -> String {
    Localization.shared.text(english)
}

/// `english` with its `%@` placeholders filled in, in order, from `arguments`.
/// A table may number them (`%2$@ … %1$@`) where its language puts them the
/// other way round.
public func L(_ english: String, _ arguments: String...) -> String {
    Localization.shared.text(english, arguments)
}

/// A window's SwiftUI content, rebuilt in the new language when it changes.
public struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var localization = Localization.shared
    let content: Content

    public var body: some View {
        content
            .id(localization.code)
            .environment(\.locale, localization.locale)
    }
}

extension View {
    /// Rebuilds this view, a window's root, when the app's language changes.
    public func localizedRoot() -> LocalizedRoot<Self> {
        LocalizedRoot(content: self)
    }
}

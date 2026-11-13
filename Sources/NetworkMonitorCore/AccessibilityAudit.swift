import AppKit
import ApplicationServices

/// Checks a window's accessibility tree for the problems a program can find
/// (#346): a control VoiceOver can't name, a control named only by its SF
/// Symbol, an image it reads as just "image".
///
/// It reads the tree through the Accessibility API, the way VoiceOver does,
/// so it sees what SwiftUI actually exposes rather than what the code meant.
/// The tests run it on windows they build in their own process, and
/// `Scripts/site-shots.swift` on the installed app's, with real data in the
/// lists. What it can't judge (whether a name makes sense, the reading order)
/// is for a person to check.
public enum AccessibilityAudit {

    public struct Problem: Hashable, CustomStringConvertible {
        /// Where it is: the roles and names leading to it.
        public let path: String
        public let rule: String
        public var description: String { "\(path): \(rule)" }
    }

    /// Roles a person acts on, which VoiceOver must be able to name.
    static let controls: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
        "AXTextArea", "AXSlider", "AXComboBox", "AXDisclosureTriangle", "AXLink", "AXIncrementor",
        "AXColorWell", "AXSegmentedControl",
    ]

    /// The window's own buttons and a scroll bar's parts, which macOS names.
    static let systemSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
        "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage", "AXSearchField",
    ]

    /// `symbols` are SF Symbols the app uses. A control named with one's
    /// default description is caught even where macOS doesn't say which
    /// symbol an element shows.
    public static func audit(_ window: AXUIElement, symbols: Set<String> = []) -> [Problem] {
        let spoken = Dictionary(symbols.compactMap { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.accessibilityDescription
                .map { ($0.lowercased(), name) }
        }, uniquingKeysWith: { first, _ in first })
        var problems: [Problem] = []
        func walk(_ element: AXUIElement, _ path: [String]) {
            let role = string(element, kAXRoleAttribute) ?? "?"
            let subrole = string(element, kAXSubroleAttribute)
            if role == "AXScrollBar" { return }
            let name = Self.name(of: element)
            let here = path + [name.map { "\(role) “\($0)”" } ?? role]
            let at = here.suffix(3).joined(separator: " › ")
            if controls.contains(role), !systemSubroles.contains(subrole ?? "") {
                if name == nil {
                    problems.append(Problem(path: at, rule: "has no name, so VoiceOver can't say what it is"))
                } else if let symbol = symbolName(element, matching: name!)
                            // Without the identifier, only a button: a segment's
                            // "Wi-Fi" is a word that happens to be a symbol's too.
                            ?? (role == "AXButton" ? spoken[name!.lowercased()]
                                ?? (symbols.contains(name!) ? name : nil) : nil) {
                    problems.append(Problem(path: at, rule: "is named only by its symbol (\(symbol)); give it a label that says what it does"))
                }
            }
            if role == "AXImage", name == nil {
                problems.append(Problem(path: at, rule: "is an image with no description; describe it, or hide it from VoiceOver if it's decoration"))
            }
            for child in children(element) { walk(child, here) }
        }
        walk(window, [])
        return problems
    }

    /// What VoiceOver calls the element: its title, its description, or the
    /// text that labels it.
    static func name(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s = string(element, attribute), !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        if let title = value(element, kAXTitleUIElementAttribute), CFGetTypeID(title) == AXUIElementGetTypeID(),
           let s = string(title as! AXUIElement, kAXValueAttribute), !s.isEmpty { return s }
        if let labels = value(element, "AXLabelUIElements") as? [AXUIElement],
           let s = labels.compactMap({ string($0, kAXValueAttribute) }).first(where: { !$0.isEmpty }) { return s }
        return nil
    }

    /// The SF Symbol the element shows, when its name is just the symbol's
    /// default description, "Gear shape, filled" for `gearshape.fill`.
    static func symbolName(_ element: AXUIElement, matching name: String) -> String? {
        guard let identifier = string(element, kAXIdentifierAttribute) else { return nil }
        // macOS 26 reads out the symbol's own name, "gearshape.fill".
        if name == identifier { return identifier }
        guard let image = NSImage(systemSymbolName: identifier, accessibilityDescription: nil),
              let spoken = image.accessibilityDescription else { return nil }
        return spoken.caseInsensitiveCompare(name) == .orderedSame ? identifier : nil
    }

    static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// Each control in the tree with its name and identifier, to say what a
    /// failed check saw.
    public static func outline(_ window: AXUIElement) -> [String] {
        var out: [String] = []
        func walk(_ e: AXUIElement) {
            let role = string(e, kAXRoleAttribute) ?? "?"
            if controls.contains(role) || role == "AXImage" {
                out.append("\(role) name=\(name(of: e) ?? "nil") title=\(string(e, kAXTitleAttribute) ?? "nil") "
                           + "description=\(string(e, kAXDescriptionAttribute) ?? "nil") id=\(string(e, kAXIdentifierAttribute) ?? "nil")")
            }
            children(e).forEach(walk)
        }
        walk(window)
        return out
    }

    /// This process's window titled `title`, read on the main thread.
    ///
    /// Asked about its own process, the Accessibility API sends no message:
    /// it calls AppKit's and SwiftUI's accessibility code directly, on the
    /// thread that asks. Read from a thread of its own while the main one
    /// kept running, SwiftUI's views were walked and updated at once, and the
    /// suite crashed now and then: "_DictionaryStorage deallocated with
    /// non-zero retain count" (#488). On the main thread nothing else runs
    /// while the tree is read, and nothing waits on anything.
    public static func auditOwnWindow(titled title: String, symbols: Set<String> = []) -> [Problem]? {
        onOwnWindow(titled: title) { audit($0, symbols: symbols) }
    }

    public static func outlineOwnWindow(titled title: String) -> [String] {
        onOwnWindow(titled: title, outline) ?? []
    }

    /// Every name in the window, whatever its role: for what VoiceOver reads
    /// off a whole element, such as the Connections map (#231).
    public static func namesOwnWindow(titled title: String) -> [String] {
        onOwnWindow(titled: title) { window in
            var out: [String] = []
            func walk(_ e: AXUIElement) {
                if let name = name(of: e) { out.append(name) }
                children(e).forEach(walk)
            }
            walk(window)
            return out
        } ?? []
    }

    /// What VoiceOver reads, in the order VO-→ goes: each element with a
    /// name or a value, as "role: name, value" (#525). A text's words are
    /// its value.
    public static func readingOrderOwnWindow(titled title: String) -> [String] {
        onOwnWindow(titled: title) { window in
            var out: [String] = []
            func walk(_ e: AXUIElement) {
                let role = string(e, kAXRoleAttribute) ?? "?"
                let words = [name(of: e), string(e, kAXValueAttribute)].compactMap { $0 }.filter { !$0.isEmpty }
                if !words.isEmpty { out.append("\(role): " + words.joined(separator: ", ")) }
                children(e).forEach(walk)
            }
            walk(window)
            return out
        } ?? []
    }

    /// Presses the first control named `name`, as VO-Space does (#525). False
    /// when there's none, or it won't be pressed.
    public static func pressOwnWindow(titled title: String, named name: String) -> Bool {
        onOwnWindow(titled: title) { window -> Bool in
            func find(_ e: AXUIElement) -> AXUIElement? {
                if Self.name(of: e) == name, controls.contains(string(e, kAXRoleAttribute) ?? "") { return e }
                for child in children(e) { if let found = find(child) { return found } }
                return nil
            }
            guard let control = find(window) else { return false }
            return AXUIElementPerformAction(control, kAXPressAction as CFString) == .success
        } ?? false
    }

    static func onOwnWindow<T>(titled title: String, _ body: (AXUIElement) -> T) -> T? {
        precondition(Thread.isMainThread, "read this process's windows on the main thread (#488)")
        let app = AXUIElementCreateApplication(getpid())
        // Now and then the list comes back without the window, a moment
        // after it's retitled or its content swapped (#455): asked again
        // once things settle, it's there.
        for attempt in 0..<5 {
            let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let window = windows.first(where: { string($0, kAXTitleAttribute) == title }) { return body(window) }
            if attempt < 4 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        }
        return nil
    }

}

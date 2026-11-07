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
    /// symbol an element shows (macOS 26 doesn't; 27 does).
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
                            ?? (role == "AXButton" ? spoken[name!.lowercased()] : nil) {
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
        guard let identifier = string(element, kAXIdentifierAttribute),
              let image = NSImage(systemSymbolName: identifier, accessibilityDescription: nil),
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

    /// This process's window titled `title`, read from another thread while
    /// the main one keeps answering: the Accessibility API asks the main
    /// thread, so asking from it would wait forever.
    public static func auditOwnWindow(titled title: String, symbols: Set<String> = [],
                                      timeout: TimeInterval = 10) -> [Problem]? {
        var result: [Problem]?
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let app = AXUIElementCreateApplication(getpid())
            AXUIElementSetMessagingTimeout(app, Float(timeout))
            let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if let window = windows.first(where: { string($0, kAXTitleAttribute) == title }) {
                result = audit(window, symbols: symbols)
            }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout + 2)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return result
    }
}

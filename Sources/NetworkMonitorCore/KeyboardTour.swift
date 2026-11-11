import AppKit
import ApplicationServices

/// Tab through a window as someone with Keyboard navigation on does, and
/// check every stop for what VoiceOver says there (#455).
///
/// It runs in the process that built the window, out of sight: no screen, no
/// pointer, nothing frontmost, so it needs no Mac lane. Tab is what AppKit
/// does with it, `selectNextKeyView`; the arrow keys go to the control with
/// focus as its key presses. Each stop is matched to the element VoiceOver
/// reads there through the Accessibility API, by where it is.
///
/// The tests run it on every window (`KeyboardTests`), `make design-shots
/// KEYBOARD=1` on windows with rows in their lists. What it can't judge
/// (whether the order makes sense to someone who can't see it, whether a
/// shortcut is worth having) is for a person.
public enum KeyboardTour {

    /// Where focus landed, and what VoiceOver says there.
    public struct Stop: CustomStringConvertible {
        public let responder: String
        /// In the Accessibility API's coordinates: from the top left of the
        /// main screen.
        public let frame: CGRect
        public let role: String?
        public let name: String?
        /// The choice made, for a switch; on or off, for a checkbox.
        public let value: String?
        /// Where the element VoiceOver reads is, which can be larger (a row
        /// round its ▸) or smaller (a button's image) than the stop.
        public var elementFrame: CGRect = .zero

        public var description: String {
            guard let role else { return "\(responder), which VoiceOver can't find" }
            let spoken = [name.map { "“\($0)”" }, value.map { "= \($0)" }].compactMap { $0 }.joined(separator: " ")
            return spoken.isEmpty ? "\(role), unnamed" : "\(role) \(spoken)"
        }
    }

    public struct Tour {
        public let stops: [Stop]
        /// Whether Tab came back round to the first stop.
        public let closes: Bool
        public var description: String {
            stops.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                + (closes ? "\n(and round again)" : "\n(Tab never came back to the first)")
        }
    }

    // MARK: Keyboard navigation, for this process

    nonisolated(unsafe) private static var saved: [(Method, IMP)] = []

    /// This process acts as with System Settings › Keyboard › Keyboard
    /// navigation on, whatever the Mac is set to: every control is a Tab
    /// stop, as SwiftUI and AppKit make them then. AppKit reads the setting
    /// itself, not through anything a process can set for itself, so the two
    /// methods that answer it are answered here. Only the tests and
    /// DesignShots call it, never the app; `stop` puts them back.
    public static func start() {
        guard saved.isEmpty else { return }
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        for (cls, selector) in [(NSApplication.self as AnyClass, #selector(getter: NSApplication.isFullKeyboardAccessEnabled)),
                                (NSWindow.self, NSSelectorFromString("_allowsAnyValidResponder"))] {
            guard let method = class_getInstanceMethod(cls, selector) else {
                preconditionFailure("\(cls) has no \(selector) on this macOS: KeyboardTour needs another way to turn on keyboard navigation")
            }
            saved.append((method, method_setImplementation(method, imp_implementationWithBlock(yes))))
        }
    }

    public static func stop() {
        for (method, imp) in saved { method_setImplementation(method, imp) }
        saved = []
    }

    // MARK: Moving

    public enum Key {
        case tab, up, down, left, right, escape, space

        var characters: String {
            switch self {
            case .tab:    return "\t"
            case .up:     return String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .down:   return String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .left:   return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right:  return String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .escape: return "\u{1B}"
            case .space:  return " "
            }
        }

        var code: UInt16 {
            switch self {
            case .tab: return 48
            case .up: return 126
            case .down: return 125
            case .left: return 123
            case .right: return 124
            case .escape: return 53
            case .space: return 49
            }
        }
    }

    /// The key pressed with focus where it is. Tab moves as AppKit moves it.
    public static func press(_ key: Key, in window: NSWindow, settle: TimeInterval = 0.3) {
        if key == .tab {
            window.selectNextKeyView(nil)
        } else {
            // Down, then up: a button is pressed as the key comes up.
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: key.characters, charactersIgnoringModifiers: key.characters,
                                             isARepeat: false, keyCode: key.code)!
                let responder = window.firstResponder ?? window
                if type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
    }

    /// A shortcut, ⌘F say, as the menus and the window take it.
    public static func shortcut(_ characters: String, in window: NSWindow, settle: TimeInterval = 0.6) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil,
                                     characters: characters, charactersIgnoringModifiers: characters,
                                     isARepeat: false, keyCode: 0)!
        if !window.performKeyEquivalent(with: event) { _ = NSApp.mainMenu?.performKeyEquivalent(with: event) }
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
    }

    // MARK: Touring

    /// Tab from nothing focused until focus comes back round, at most
    /// `limit` times.
    public static func walk(_ window: NSWindow, limit: Int = 80) -> Tour {
        window.makeFirstResponder(nil)
        var stops: [Stop] = []
        var seen: [ObjectIdentifier] = []
        for _ in 0..<limit {
            window.selectNextKeyView(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            guard let responder = window.firstResponder, responder !== window else { break }
            let id = ObjectIdentifier(responder)
            if seen.first == id { return Tour(stops: stops, closes: true) }
            // Round a loop that leaves the first stop out.
            if seen.contains(id) { break }
            seen.append(id)
            stops.append(focused(in: window) ?? Stop(responder: "\(type(of: responder))", frame: .zero,
                                                     role: nil, name: nil, value: nil))
        }
        return Tour(stops: stops, closes: false)
    }

    /// Where focus is, and what VoiceOver says there.
    public static func focused(in window: NSWindow) -> Stop? {
        guard let view = focusedView(in: window) else { return nil }
        var frame = CGRect.zero
        let match = AccessibilityAudit.onOwnWindow(titled: window.title) { element -> Element? in
            frame = axFrame(of: view, inWindowAt: self.frame(of: element))
            return best(for: frame, among: elements(in: element))
        } ?? nil
        let responder = "\(type(of: view))"
        guard let match else { return Stop(responder: responder, frame: frame, role: nil, name: nil, value: nil) }
        return Stop(responder: responder, frame: frame, role: match.role,
                    name: AccessibilityAudit.name(of: match.element), value: value(of: match.element),
                    elementFrame: match.frame)
    }

    /// The view with focus: a text field's own field rather than the
    /// editor it lends it.
    static func focusedView(in window: NSWindow) -> NSView? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSView {
            return field
        }
        return window.firstResponder as? NSView
    }

    /// The view's place as the Accessibility API gives it, measured from
    /// where it says the window is rather than from the screens: with the
    /// displays asleep or the Mac locked, AppKit's screens and the
    /// Accessibility API's disagreed, and no stop matched (#455).
    static func axFrame(of view: NSView, inWindowAt windowFrame: CGRect?) -> CGRect {
        guard let window = view.window else { return .zero }
        let r = view.convert(view.bounds, to: nil)
        if let windowFrame {
            return CGRect(x: windowFrame.minX + r.minX, y: windowFrame.minY + window.frame.height - r.maxY,
                          width: r.width, height: r.height)
        }
        let screen = window.convertToScreen(r)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: screen.minX, y: top - screen.maxY, width: screen.width, height: screen.height)
    }

    struct Element {
        let element: AXUIElement
        let role: String
        let subrole: String?
        let frame: CGRect
    }

    static func elements(in window: AXUIElement) -> [Element] {
        var out: [Element] = []
        func walk(_ e: AXUIElement) {
            let role = AccessibilityAudit.string(e, kAXRoleAttribute) ?? "?"
            if role == "AXScrollBar" { return }
            if let frame = frame(of: e) {
                out.append(Element(element: e, role: role, subrole: AccessibilityAudit.string(e, kAXSubroleAttribute),
                                   frame: frame))
            }
            AccessibilityAudit.children(e).forEach(walk)
        }
        walk(window)
        return out
    }

    static func frame(of e: AXUIElement) -> CGRect? {
        guard let p = AccessibilityAudit.value(e, kAXPositionAttribute),
              let s = AccessibilityAudit.value(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Roles focus can be on that aren't controls: a list, a group made one
    /// stop.
    static let focusRoles: Set<String> = AccessibilityAudit.controls.union([
        "AXGroup", "AXTabGroup", "AXRadioGroup", "AXList", "AXTable", "AXOutline", "AXScrollArea", "AXRow",
        "AXCell", "AXStaticText", "AXWebArea",
    ])

    /// The element VoiceOver reads where focus is: the one in the same place,
    /// or the smallest control round it (a toolbar item round its button).
    static func best(for frame: CGRect, among elements: [Element]) -> Element? {
        func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let i = a.intersection(b)
            guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
            return (i.width * i.height) / (a.width * a.height + b.width * b.height - i.width * i.height)
        }
        let candidates = elements.filter { focusRoles.contains($0.role) && !(AccessibilityAudit.systemSubroles.contains($0.subrole ?? "") && $0.subrole != "AXSearchField") }
        // A hosting view's group the size of the stop says nothing; its
        // named control does.
        let same = candidates.filter { overlap($0.frame, frame) > 0.45 }
            .sorted { (overlap($0.frame, frame), named($0)) > (overlap($1.frame, frame), named($1)) }
        if let match = same.first(where: { named($0) == 1 }) ?? same.first { return match }
        let controls = candidates.filter { AccessibilityAudit.controls.contains($0.role) }
        if let round = controls.filter({ $0.frame.insetBy(dx: -1, dy: -1).contains(frame) })
            .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return round
        }
        // A button drawn smaller than where it takes clicks: its image, a
        // ▸, inside the stop, and the only control there.
        let inside = controls.filter { frame.insetBy(dx: -1, dy: -1).contains($0.frame) && $0.frame.width > 1 }
        return inside.count == 1 ? inside[0] : nil
    }

    private static func named(_ e: Element) -> Int { AccessibilityAudit.name(of: e.element) == nil ? 0 : 1 }

    /// A switch's choice, a checkbox's state, a field's text.
    static func value(of e: AXUIElement) -> String? {
        let role = AccessibilityAudit.string(e, kAXRoleAttribute)
        if role == "AXTabGroup" || role == "AXRadioGroup" {
            let chosen = AccessibilityAudit.children(e).first {
                (AccessibilityAudit.value($0, kAXValueAttribute) as? NSNumber)?.intValue == 1
                    || AccessibilityAudit.value($0, kAXSelectedAttribute) as? Bool == true
            }
            return chosen.flatMap { AccessibilityAudit.name(of: $0) }
        }
        if role == "AXCheckBox" {
            return (AccessibilityAudit.value(e, kAXValueAttribute) as? NSNumber).map { $0.intValue == 1 ? "on" : "off" }
        }
        if let s = AccessibilityAudit.string(e, kAXValueAttribute), !s.isEmpty, s.count <= 40 { return s }
        if let s = AccessibilityAudit.string(e, "AXValueDescription"), !s.isEmpty { return s }
        return nil
    }

    // MARK: Checking

    /// What a person with the keyboard or VoiceOver would trip on: a stop
    /// VoiceOver can't name, a control reached twice (a switch and each of
    /// its choices), a control Tab never reaches, a loop that doesn't come
    /// back round.
    public static func problems(in window: NSWindow, _ tour: Tour) -> [String] {
        var problems: [String] = []
        for (index, stop) in tour.stops.enumerated() where stop.role == nil || stop.name == nil {
            problems.append("stop \(index + 1), \(stop), has nothing VoiceOver can read out")
        }
        let placed = tour.stops.enumerated().filter { $0.element.frame.width > 0 }
        for (i, outer) in placed {
            let inner = placed.filter { $0.offset != i && outer.frame.insetBy(dx: -1, dy: -1).contains($0.element.frame)
                && outer.frame != $0.element.frame }
            // A control is one stop: a switch, the sidebar, a button. A list
            // may hold a button or two of its own (Show all), not one a row.
            let isList = ["AXScrollArea", "AXList", "AXTable", "AXOutline"].contains(outer.role ?? "")
            // Only what holds choices: a button over another is a row
            // scrolled out of sight under the one below the list.
            let holds = isList || ["AXGroup", "AXTabGroup", "AXRadioGroup"].contains(outer.role ?? "")
            guard holds, !inner.isEmpty, !isList || inner.count > 2 else { continue }
            for (j, stop) in inner {
                problems.append("stop \(j + 1), \(stop), is inside stop \(i + 1), \(outer)"
                                + (isList ? ": each row a stop as well as the list" : ": one control, two stops"))
            }
        }
        if !tour.closes { problems.append("Tab doesn't come back round to the first stop") }
        // Every control is in a stop, or inside one (a switch's choices, a
        // list's rows), or is the window's own.
        let unreached = AccessibilityAudit.onOwnWindow(titled: window.title) { root -> [String] in
            elements(in: root).filter { element in
                AccessibilityAudit.controls.contains(element.role)
                    && !AccessibilityAudit.systemSubroles.contains(element.subrole ?? "")
                    && element.frame.width > 1 && element.frame.height > 1
                    && AccessibilityAudit.value(element.element, kAXEnabledAttribute) as? Bool != false
                    && !placed.contains { stop in
                        stop.element.elementFrame == element.frame
                            || stop.element.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
                    }
            }.map { "\($0.role) “\(AccessibilityAudit.name(of: $0.element) ?? "unnamed")” can't be reached with Tab" }
        } ?? ["couldn't read the \(window.title) window's accessibility tree"]
        return problems + unreached
    }
}

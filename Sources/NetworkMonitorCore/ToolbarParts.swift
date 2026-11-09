import AppKit

/// What every section's toolbar shares (#436), so Usage History,
/// Connections and Ads and Trackers read the same way: the period centred,
/// ‹ Today ›, search, then the gear.
enum PeriodControl {
    static func configure(_ control: NSSegmentedControl, target: AnyObject, action: Selector) {
        control.segmentCount = HistoryScale.allCases.count
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = target
        control.action = action
    }

    /// Day, Week, Month and Year, each segment as wide as the widest, as
    /// Calendar has them, now there's room for it. Again when the language
    /// changes, since the widest word changes with it.
    static func name(_ control: NSSegmentedControl) {
        let font = control.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        var widest: CGFloat = 0
        for (index, scale) in HistoryScale.allCases.enumerated() {
            control.setLabel(scale.label, forSegment: index)
            widest = max(widest, (scale.label as NSString).size(withAttributes: [.font: font]).width)
        }
        let width = max(ceil(widest) + 26, segmentWidth)
        for index in 0..<control.segmentCount { control.setWidth(width, forSegment: index) }
    }

    /// The narrowest a segment is, whatever the language.
    static let segmentWidth: CGFloat = 64
}

/// Search in a section's toolbar (#436): a magnifying glass until it's
/// clicked or ⌘F is pressed, then a field, as in Mail and Finder.
///
/// - It grows out of the glass and shrinks back into it, in one movement.
/// - Clicking anywhere else, or Escape, closes it while it's empty.
/// - Escape with a search in it clears the search first; again, it closes.
/// - Holding a search, it stays open, so what narrows the list stays in
///   sight; the row under the toolbar shows it as a chip too, cleared with
///   one click like any other filter.
///
/// One `NSSearchToolbarItem` whose width the app sets: at the glass's width
/// AppKit draws it as the glass itself. Left to AppKit, it folded only when
/// the toolbar ran out of room, and opened in two steps.
public final class ToolbarSearch: NSObject, NSSearchFieldDelegate {
    static let width: CGFloat = 240
    /// The glass's width, at which the field draws as the glass: a circle
    /// as tall as the toolbar's buttons, as the gear beside it, its magnifying
    /// glass centred (measured in `make design-shots`; narrower, it was an
    /// upright oval).
    static let glassWidth: CGFloat = 36

    public let item: NSSearchToolbarItem
    var onChange: (String) -> Void = { _ in }
    /// Whether the field is open, or opening, rather than the glass.
    public private(set) var isOpen = false
    private var placeholder = ""
    private let size: NSLayoutConstraint
    private var clicks: Any?

    init(_ identifier: NSToolbarItem.Identifier) {
        item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.preferredWidthForSearchField = Self.width
        item.resignsFirstResponderWithCancel = true
        let field = item.searchField
        field.translatesAutoresizingMaskIntoConstraints = false
        size = field.widthAnchor.constraint(equalToConstant: Self.glassWidth)
        // Just under required: the app's say over the field's width, without
        // fighting the toolbar's own constraints.
        size.priority = NSLayoutConstraint.Priority(999)
        size.isActive = true
        super.init()
        field.delegate = self
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            return self.clicked(event) ? nil : event
        }
    }

    deinit {
        if let clicks { NSEvent.removeMonitor(clicks) }
    }

    public var field: NSSearchField { item.searchField }

    // MARK: For the toolbar's delegate

    var restingIdentifier: NSToolbarItem.Identifier { item.itemIdentifier }
    var identifiers: [NSToolbarItem.Identifier] { [item.itemIdentifier] }

    func item(for identifier: NSToolbarItem.Identifier, in toolbar: NSToolbar) -> NSToolbarItem? {
        identifier == item.itemIdentifier ? item : nil
    }

    /// The words, from `init` and when the language changes.
    func name(placeholder: String, help: String) {
        self.placeholder = placeholder
        field.placeholderString = isOpen ? placeholder : nil
        field.setAccessibilityLabel(placeholder)
        item.label = L("Search")
        item.paletteLabel = L("Search")
        item.toolTip = help
    }

    // MARK: Opening and closing

    /// The model's search, put back in the field: a section shown again, or
    /// a search cleared from its chip.
    public func show(_ text: String) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        if !text.isEmpty {
            open(focus: false)
        } else if !hasFocus {
            finish()
        }
    }

    /// ⌘F, or the glass clicked: the field, with the cursor in it.
    public func begin() { open(focus: true) }

    /// Back to the glass, if the field holds no search.
    public func finish() {
        guard isOpen, field.stringValue.isEmpty else { return }
        isOpen = false
        if hasFocus { field.window?.makeFirstResponder(nil) }
        field.placeholderString = nil
        resize(to: Self.glassWidth)
    }

    private func open(focus: Bool) {
        let takeFocus = { [weak self] in
            guard let self, focus, self.isOpen else { return }
            self.field.window?.makeFirstResponder(self.field)
        }
        guard !isOpen else { return takeFocus() }
        isOpen = true
        field.placeholderString = placeholder
        // The cursor goes in once it's open: focused while it grows, AppKit
        // started its own opening too, and it grew in two steps.
        resize(to: Self.width, then: takeFocus)
    }

    /// One movement from the glass to the field or back, as Motion says.
    private func resize(to width: CGFloat, then done: @escaping () -> Void = {}) {
        guard field.window?.isVisible == true, !Motion.isReduced else {
            size.constant = width
            done()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration
            context.timingFunction = Motion.timing
            context.allowsImplicitAnimation = true
            size.animator().constant = width
        } completionHandler: { done() }
    }

    private var hasFocus: Bool { field.currentEditor() != nil }

    /// Clicks on the glass open it; clicks anywhere else close an empty
    /// field. True when the click is taken here.
    private func clicked(_ event: NSEvent) -> Bool {
        guard let window = field.window, event.window === window else { return false }
        let inField = field.convert(field.bounds, to: nil).contains(event.locationInWindow)
        if !isOpen && inField {
            begin()
            return true
        }
        if isOpen && !inField && field.stringValue.isEmpty {
            // After the click is handled, so a click on a control still works.
            DispatchQueue.main.async { [weak self] in self?.finish() }
        }
        return false
    }

    // MARK: NSSearchFieldDelegate

    /// Typed into without a click, as with VoiceOver or Tab: opened too.
    public func controlTextDidBeginEditing(_ notification: Notification) {
        open(focus: false)
    }

    public func controlTextDidChange(_ notification: Notification) {
        onChange(field.stringValue)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        // Left for another control, empty: the glass again.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasFocus else { return }
            self.finish()
        }
    }

    /// Escape: clears the search, then, pressed again, closes the field.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if field.stringValue.isEmpty {
            finish()
        } else {
            field.stringValue = ""
            onChange("")
        }
        return true
    }
}

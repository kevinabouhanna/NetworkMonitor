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
/// - Clicking anywhere else, or Escape, folds it back while it's empty.
/// - Escape with a search in it clears the search first; again, it folds.
/// - Holding a search, it stays open, so what narrows the list stays in
///   sight; the row under the toolbar shows it as a chip too, cleared with
///   one click like any other filter.
///
/// `NSSearchToolbarItem` folds itself into the glass when its field has no
/// width to spare and opens to `preferredWidthForSearchField` while it's
/// used; a zero width while it's empty is what makes the glass its resting
/// state.
public final class ToolbarSearch: NSObject, NSSearchFieldDelegate {
    static let width: CGFloat = 240
    /// The narrowest it gets while it holds a search, so the search stays
    /// readable; up to `width` when there's room.
    static let minimumOpenWidth: CGFloat = 140

    public let item: NSSearchToolbarItem
    var onChange: (String) -> Void = { _ in }
    private let folded: NSLayoutConstraint
    private let open: NSLayoutConstraint
    private var isEditing = false
    private var clicks: Any?

    init(_ identifier: NSToolbarItem.Identifier) {
        item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.preferredWidthForSearchField = Self.width
        item.resignsFirstResponderWithCancel = true
        let field = item.searchField
        field.translatesAutoresizingMaskIntoConstraints = false
        folded = field.widthAnchor.constraint(equalToConstant: 0)
        open = field.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumOpenWidth)
        folded.priority = .defaultHigh
        open.priority = .defaultHigh
        super.init()
        field.delegate = self
        fold()
        // A click outside the open, empty field folds it, wherever it lands:
        // the list, the chart and empty space don't take the keyboard from
        // it, so on its own the field would stay open.
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.clicked(event)
            return event
        }
    }

    deinit {
        if let clicks { NSEvent.removeMonitor(clicks) }
    }

    public var field: NSSearchField { item.searchField }

    /// The words, from `init` and when the language changes.
    func name(placeholder: String, help: String) {
        field.placeholderString = placeholder
        item.label = L("Search")
        item.toolTip = help
    }

    /// The model's search, put back in the field: a section shown again, or
    /// a search cleared from its chip.
    public func show(_ text: String) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        if text.isEmpty && !hasFocus { item.endSearchInteraction() }
        fold()
    }

    /// ⌘F: opens the field and puts the cursor in it.
    public func begin() { item.beginSearchInteraction() }

    /// Whether it rests open, holding a search, rather than as the glass.
    public var isOpen: Bool { open.isActive }

    /// Folds it back to the glass, if it holds no search.
    public func finish() {
        guard field.stringValue.isEmpty else { return }
        isEditing = false
        item.endSearchInteraction()
        fold()
    }

    private var hasFocus: Bool { field.currentEditor() != nil }

    private func clicked(_ event: NSEvent) {
        guard hasFocus, field.stringValue.isEmpty, let window = field.window, event.window === window else { return }
        guard !field.convert(field.bounds, to: nil).contains(event.locationInWindow) else { return }
        // After the click is handled, so a click on a control still works.
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    private func fold() {
        let shut = field.stringValue.isEmpty && !isEditing
        folded.isActive = shut
        open.isActive = !shut
    }

    public func controlTextDidBeginEditing(_ notification: Notification) {
        isEditing = true
        fold()
    }

    public func controlTextDidChange(_ notification: Notification) {
        onChange(field.stringValue)
        fold()
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        isEditing = false
        fold()
    }

    /// Escape: clears the search, then, pressed again, folds the field.
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if field.stringValue.isEmpty {
            finish()
        } else {
            field.stringValue = ""
            onChange("")
            fold()
        }
        return true
    }
}

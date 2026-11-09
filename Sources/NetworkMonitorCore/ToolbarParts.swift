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

/// Search in a section's toolbar (#436): a magnifying glass button until
/// it's clicked or ⌘F is pressed, then a search field in its place, as in
/// Mail and Finder.
///
/// - Clicking anywhere else, or Escape, puts the glass back while the field
///   is empty.
/// - Escape with a search in it clears the search first; again, it closes.
/// - Holding a search, the field stays, so what narrows the list stays in
///   sight; the row under the toolbar shows it as a chip too, cleared with
///   one click like any other filter.
///
/// Two toolbar items swapped in one place, rather than one search item
/// asked to fold itself: `NSSearchToolbarItem` folds only when the toolbar
/// runs out of room, and stayed open after a click elsewhere.
public final class ToolbarSearch: NSObject, NSSearchFieldDelegate {
    static let width: CGFloat = 240

    let glassID: NSToolbarItem.Identifier
    let fieldID: NSToolbarItem.Identifier
    private let glass: NSToolbarItem
    private let fieldItem: NSSearchToolbarItem
    private weak var toolbar: NSToolbar?
    var onChange: (String) -> Void = { _ in }
    private var clicks: Any?

    init(_ identifier: NSToolbarItem.Identifier) {
        fieldID = identifier
        glassID = NSToolbarItem.Identifier(identifier.rawValue + ".glass")
        glass = NSToolbarItem(itemIdentifier: glassID)
        fieldItem = NSSearchToolbarItem(itemIdentifier: identifier)
        super.init()
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L("Search"))
        glass.isBordered = true
        glass.target = self
        glass.action = #selector(glassClicked)
        fieldItem.preferredWidthForSearchField = Self.width
        fieldItem.resignsFirstResponderWithCancel = true
        fieldItem.searchField.delegate = self
        // A click outside the empty field closes it, wherever it lands: the
        // list, the chart and empty space don't take the keyboard from it.
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.clicked(event)
            return event
        }
    }

    deinit {
        if let clicks { NSEvent.removeMonitor(clicks) }
    }

    public var field: NSSearchField { fieldItem.searchField }

    // MARK: For the toolbar's delegate

    /// What the toolbar starts with: the field when there's a search.
    var restingIdentifier: NSToolbarItem.Identifier { field.stringValue.isEmpty ? glassID : fieldID }

    var identifiers: [NSToolbarItem.Identifier] { [glassID, fieldID] }

    func item(for identifier: NSToolbarItem.Identifier, in toolbar: NSToolbar) -> NSToolbarItem? {
        guard identifier == glassID || identifier == fieldID else { return nil }
        self.toolbar = toolbar
        return identifier == glassID ? glass : fieldItem
    }

    /// The words, from `init` and when the language changes.
    func name(placeholder: String, help: String) {
        field.placeholderString = placeholder
        // Named for what it searches, not "Search" alone, which is only the
        // glass's own name to VoiceOver.
        glass.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: placeholder)
        for item in [glass, fieldItem] as [NSToolbarItem] {
            item.label = L("Search")
            item.paletteLabel = L("Search")
            item.toolTip = help
        }
        glass.label = placeholder
    }

    // MARK: Opening and closing

    /// Whether the field is showing rather than the glass.
    public var isOpen: Bool { toolbar?.items.contains { $0.itemIdentifier == fieldID } ?? false }

    /// The model's search, put back in the field: a section shown again, or
    /// a search cleared from its chip.
    public func show(_ text: String) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        if !text.isEmpty { place(fieldID) } else if !hasFocus { place(glassID) }
    }

    /// ⌘F, or the glass clicked: the field, with the cursor in it.
    public func begin() {
        place(fieldID)
        DispatchQueue.main.async { [weak self] in self?.fieldItem.beginSearchInteraction() }
    }

    /// Back to the glass, if the field holds no search.
    public func finish() {
        guard field.stringValue.isEmpty, isOpen else { return }
        if hasFocus { field.window?.makeFirstResponder(nil) }
        place(glassID)
    }

    @objc private func glassClicked() { begin() }

    private var hasFocus: Bool { field.currentEditor() != nil }

    private func place(_ identifier: NSToolbarItem.Identifier) {
        guard let toolbar,
              let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == glassID || $0.itemIdentifier == fieldID }),
              toolbar.items[index].itemIdentifier != identifier else { return }
        toolbar.removeItem(at: index)
        toolbar.insertItem(withItemIdentifier: identifier, at: index)
    }

    private func clicked(_ event: NSEvent) {
        guard isOpen, field.stringValue.isEmpty, let window = field.window, event.window === window,
              !field.convert(field.bounds, to: nil).contains(event.locationInWindow) else { return }
        // After the click is handled, so a click on a control still works.
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    // MARK: NSSearchFieldDelegate

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

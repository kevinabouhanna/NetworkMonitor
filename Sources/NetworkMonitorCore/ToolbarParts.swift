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
/// clicked or ⌘F is pressed, then a field, as in Mail and Finder. It stays
/// open while it holds a search, so what narrows the list stays in sight, and
/// folds back once it's emptied and left.
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

    init(_ identifier: NSToolbarItem.Identifier) {
        item = NSSearchToolbarItem(itemIdentifier: identifier)
        item.preferredWidthForSearchField = Self.width
        let field = item.searchField
        field.translatesAutoresizingMaskIntoConstraints = false
        folded = field.widthAnchor.constraint(equalToConstant: 0)
        open = field.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumOpenWidth)
        folded.priority = .defaultHigh
        open.priority = .defaultHigh
        super.init()
        field.delegate = self
        fold()
    }

    public var field: NSSearchField { item.searchField }

    /// The words, from `init` and when the language changes.
    func name(placeholder: String, help: String) {
        field.placeholderString = placeholder
        item.label = L("Search")
        item.toolTip = help
    }

    /// The model's search, put back in the field: a section shown again, or
    /// a search set elsewhere.
    public func show(_ text: String) {
        guard field.stringValue != text else { return }
        field.stringValue = text
        fold()
    }

    /// ⌘F: opens the field and puts the cursor in it.
    public func begin() { item.beginSearchInteraction() }

    /// Whether it rests open, holding a search, rather than as the glass.
    public var isOpen: Bool { open.isActive }

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
}

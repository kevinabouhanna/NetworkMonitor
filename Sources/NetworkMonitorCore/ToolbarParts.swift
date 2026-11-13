import AppKit
import SwiftUI

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

/// What a section shows (#524): its list, the list with the map or the chart,
/// or the map or the chart alone. Connections has List · Both · Map, Usage
/// History and Ads and Trackers List · Both · Chart, all through `ViewControl`
/// so the three read the same.
public protocol SectionLayout: Hashable, CaseIterable where AllCases == [Self] {
    var label: String { get }
    /// The segment's SF Symbol.
    var symbol: String { get }
}

/// Usage History's and Ads and Trackers' View (#524): the list, the list
/// with the chart beside it (#534), or the chart filling the window.
public enum ChartLayout: String, SectionLayout, Identifiable {
    case list, both, chart
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .list:  return L("List")
        case .both:  return L("Both")
        case .chart: return L("Chart")
        }
    }
    public var symbol: String {
        switch self {
        case .list:  return "list.bullet"
        case .both:  return "rectangle.split.2x1"
        case .chart: return "chart.bar"
        }
    }

    /// Whether the list shows, and so the controls that only change the list.
    public var showsList: Bool { self != .chart }
    public var showsChart: Bool { self != .list }
}

/// The View control at the leading end of a section's toolbar, before the
/// period (#524): a segment per layout, each an SF Symbol named and
/// tooltipped with its layout's name, one Tab stop with ← and → as every
/// `NSSegmentedControl` has. Connections', Usage History's and Ads and
/// Trackers' are the same control.
enum ViewControl {
    static let identifier = NSToolbarItem.Identifier("layout")

    static func configure<Layout: SectionLayout>(_ control: NSSegmentedControl, _: Layout.Type,
                                                 target: AnyObject, action: Selector) {
        control.segmentCount = Layout.allCases.count
        control.trackingMode = .selectOne
        control.target = target
        control.action = action
    }

    /// The segments' pictures and names, from `init` and when the language changes.
    static func name<Layout: SectionLayout>(_ control: NSSegmentedControl, _: Layout.Type) {
        for (index, layout) in Layout.allCases.enumerated() {
            control.setImage(NSImage(systemSymbolName: layout.symbol, accessibilityDescription: layout.label),
                             forSegment: index)
            control.setToolTip(layout.label, forSegment: index)
        }
    }

    static func select<Layout: SectionLayout>(_ layout: Layout, in control: NSSegmentedControl) {
        control.selectedSegment = Layout.allCases.firstIndex(of: layout) ?? 0
    }

    static func chosen<Layout: SectionLayout>(_ control: NSSegmentedControl) -> Layout {
        Layout.allCases[max(control.selectedSegment, 0)]
    }

    /// The toolbar item's name and tooltip: what the middle segment puts together.
    static func names(chart: Bool) -> (label: String, help: String) {
        (L("View"), chart ? L("The list, both side by side, or the chart") : L("The list, both side by side, or the map"))
    }
}

/// Both, in every section (#534): the list on the left, and the map or the
/// chart on the right on a card (`splitCard()`), whose edge is what divides
/// them. Connections' split, which Usage History and Ads and Trackers share
/// so the three read the same.
struct SideBySide<Leading: View, Trailing: View>: View {
    @ViewBuilder let list: Leading
    @ViewBuilder let detail: Trailing

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: SplitMetrics.gap) {
                // Tab goes through the list, then the map or the chart: by
                // where they sit alone, it went row, zoom button, row (#455).
                list.frame(width: SplitMetrics.listWidth(geometry.size.width))
                    .environment(\.splitListWidth, SplitMetrics.listWidth(geometry.size.width))
                    .focusSection()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
            }
        }
    }
}

private struct SplitListWidthKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    var splitListWidth: CGFloat? {
        get { self[SplitListWidthKey.self] }
        set { self[SplitListWidthKey.self] = newValue }
    }
}

enum SplitMetrics {
    /// Beside the chart or the map, a row's bar gives way before its name
    /// (#534): it takes what the list's width leaves once the row's fixed
    /// parts (`fixed`: padding, icons, gaps, the figure) and `nameRoom` are
    /// counted, between `barLeast` and its usual width, `most`. On its own,
    /// the list keeps every bar at `most`.
    static func bar(listWidth: CGFloat?, fixed: CGFloat, most: CGFloat) -> CGFloat {
        guard let listWidth else { return most }
        return min(most, max(barLeast, listWidth - fixed - nameRoom))
    }
    /// What a row's name keeps before its bar gives way.
    static let nameRoom: CGFloat = 170
    /// The shortest a row's bar gets, still a bar to compare.
    static let barLeast: CGFloat = 60
    /// The list's share of the width, the rest going to what's beside it.
    static let listShare: CGFloat = 0.46
    static let gap: CGFloat = 14
    static let cornerRadius: CGFloat = 8

    static func listWidth(_ width: CGFloat) -> CGFloat { (width * listShare).rounded() }
}

extension View {
    /// The card the map or the chart sits on beside the list, and the map
    /// on its own.
    func splitCard() -> some View {
        background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: SplitMetrics.cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: SplitMetrics.cornerRadius))
    }
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
    /// Where focus was before ⌘F, to go back to when the search closes (#455).
    private weak var focusBefore: NSResponder?
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
        AppKitToolbarNames.name(item)
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
    public func begin() {
        if !hasFocus, let window = field.window, window.firstResponder !== window {
            focusBefore = window.firstResponder
        }
        open(focus: true)
    }

    /// Back to the glass, if the field holds no search.
    public func finish() {
        guard isOpen, field.stringValue.isEmpty else { return }
        isOpen = false
        if hasFocus, let window = field.window {
            // Back where it was, as long as that's still in the window.
            if let view = focusBefore as? NSView, view.window === window, view.canBecomeKeyView {
                window.makeFirstResponder(view)
            } else {
                window.makeFirstResponder(nil)
            }
        }
        focusBefore = nil
        field.placeholderString = nil
        resize(to: glassWidth)
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

    /// Round: as wide as the field is tall where it's drawn, the toolbar's
    /// buttons being taller on some displays than others.
    private var glassWidth: CGFloat {
        field.frame.height > 0 ? field.frame.height : Self.glassWidth
    }

    /// Kept round as the toolbar lays out, while it's the glass.
    func fitGlass() {
        AppKitToolbarNames.name(item)
        guard !isOpen, size.constant != glassWidth else { return }
        size.constant = glassWidth
    }

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

/// AppKit's own toolbar buttons, named in the app's language (#621): the
/// sidebar's button and the search's glass. AppKit names them from its own
/// strings, in the language the app was launched in, so after the language
/// changed in Settings, VoiceOver read "Sidebar" and "Search" in English in a
/// Chinese window until the app was opened again. Named again whenever the
/// toolbar is shown or the language changes. The sidebar button's tooltip
/// ("Hide Sidebar", read as its hint after a pause) AppKit sets again each
/// time it checks the button, so it stays in the launch language until then.
enum AppKitToolbarNames {
    static func name(_ toolbar: NSToolbar?) {
        for item in toolbar?.items ?? [] {
            if item.itemIdentifier == .toggleSidebar {
                item.label = L("Sidebar")
                item.paletteLabel = L("Sidebar")
            } else if let search = item as? NSSearchToolbarItem {
                name(search)
            }
        }
    }

    /// The glass is AppKit's button beside the field, and the field's ✕ its
    /// clear button: neither takes the field's own name.
    static func name(_ search: NSSearchToolbarItem) {
        guard let holder = search.searchField.superview else { return }
        func walk(_ view: NSView) {
            for child in view.subviews {
                if let button = child as? NSButton {
                    if String(describing: type(of: button)).contains("Clear") {
                        button.setAccessibilityLabel(L("Clear"))
                    } else {
                        button.setAccessibilityLabel(L("Search"))
                        button.setAccessibilityHelp(search.toolTip)
                    }
                }
                walk(child)
            }
        }
        walk(holder)
    }
}

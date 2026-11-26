import Combine
import Foundation

/// Which of the popover's views show, and the order of the four buttons
/// (#802), from Settings › General › Popover.
///
/// Live is a line above the buttons rather than a button, so it can be
/// hidden but not moved; the four under it can be both. One view always
/// shows. The popover opens on Live, or on the first view shown while Live is
/// hidden.
public final class PopoverLayout: ObservableObject {
    /// The four buttons as they came, and as Kevin keeps them.
    public static let defaultOrder: [PopoverSection] = [.today, .companies, .blocked, .connection]

    @Published public private(set) var order: [PopoverSection]
    @Published public private(set) var hidden: Set<PopoverSection>

    static let orderKey = "popoverOrder"
    static let hiddenKey = "popoverHidden"
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let saved = (defaults?.stringArray(forKey: Self.orderKey) ?? []).compactMap(PopoverSection.init)
        order = Self.sanitized(saved)
        var hidden = Set((defaults?.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(PopoverSection.init))
        if hidden.count >= PopoverSection.allCases.count { hidden = [] }
        // Live or Network holds the speed test: one of them shows.
        if hidden.contains(.live) { hidden.remove(.connection) }
        self.hidden = hidden
    }

    /// The saved order with anything unknown or repeated left out, and any
    /// view it doesn't name added at the end, in its default place's order.
    static func sanitized(_ saved: [PopoverSection]) -> [PopoverSection] {
        var seen = Set<PopoverSection>()
        let kept = saved.filter { defaultOrder.contains($0) && seen.insert($0).inserted }
        return kept + defaultOrder.filter { !seen.contains($0) }
    }

    /// Every view, as Settings lists them: Live, then the four.
    public var rows: [PopoverSection] { [.live] + order }

    public var showsLive: Bool { isShown(.live) }
    /// The buttons shown, in order.
    public var buttons: [PopoverSection] { order.filter(isShown) }

    public func isShown(_ section: PopoverSection) -> Bool { !hidden.contains(section) }

    /// What the popover opens on.
    public var opening: PopoverSection { showsLive ? .live : buttons.first ?? .today }

    /// Where the speed test is: Live, or Network while Live is hidden, so it's
    /// never out of reach in the popover.
    public var speedTestSection: PopoverSection { showsLive ? .live : .connection }

    /// The last view shown can't be hidden, nor the last of Live and Network,
    /// which hold the speed test.
    public func canHide(_ section: PopoverSection) -> Bool {
        guard isShown(section), hidden.count < PopoverSection.allCases.count - 1 else { return false }
        switch section {
        case .live:       return isShown(.connection)
        case .connection: return showsLive
        default:          return true
        }
    }

    /// Why a view can't be hidden, for its tick's tooltip.
    public func whyShown(_ section: PopoverSection) -> String? {
        guard isShown(section), !canHide(section) else { return nil }
        if hidden.count >= PopoverSection.allCases.count - 1 { return L("One view always shows") }
        return L("The speed test is in Live, or in Network while Live is hidden: one of them always shows")
    }

    public func setShown(_ section: PopoverSection, _ shown: Bool) {
        if shown {
            hidden.remove(section)
        } else {
            guard canHide(section) else { return }
            hidden.insert(section)
        }
        save()
    }

    /// Moves one of the four buttons to `index` among them.
    public func move(_ section: PopoverSection, to index: Int) {
        guard let from = order.firstIndex(of: section) else { return }
        let to = min(max(index, 0), order.count - 1)
        guard from != to else { return }
        var order = self.order
        order.remove(at: from)
        order.insert(section, at: to)
        self.order = order
        save()
    }

    public func move(_ section: PopoverSection, by offset: Int) {
        guard let from = order.firstIndex(of: section) else { return }
        move(section, to: from + offset)
    }

    public func canMove(_ section: PopoverSection, by offset: Int) -> Bool {
        guard let from = order.firstIndex(of: section) else { return false }
        return order.indices.contains(from + offset)
    }

    public var isDefault: Bool { order == Self.defaultOrder && hidden.isEmpty }

    /// Every view shown, in the order they came.
    public func restore() {
        order = Self.defaultOrder
        hidden = []
        save()
    }

    private func save() {
        defaults?.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults?.set(PopoverSection.allCases.filter(hidden.contains).map(\.rawValue), forKey: Self.hiddenKey)
    }
}

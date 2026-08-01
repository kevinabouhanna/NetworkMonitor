import Foundation

/// One row in the popover list.
public struct UsageRow: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let bytesIn: Int64
    public let bytesOut: Int64
    public let bundlePath: String?
    public let isSystem: Bool
    /// Moved bytes within the last couple of seconds.
    public let isActive: Bool

    public var total: Int64 { bytesIn + bytesOut }

    public init(id: String, displayName: String, bytesIn: Int64, bytesOut: Int64,
                bundlePath: String?, isSystem: Bool, isActive: Bool) {
        self.id = id
        self.displayName = displayName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.bundlePath = bundlePath
        self.isSystem = isSystem
        self.isActive = isActive
    }
}

extension UsageRow {

    /// Default window in which an app must have moved bytes to count as active.
    ///
    /// Matches `PowerProfile.performance`. On battery the caller passes a longer
    /// one, because the dot must not blink off between samples that are further
    /// apart — see `PowerProfile.activityWindow`.
    public static let activityWindow: TimeInterval = 2.0

    /// Biggest first; ties broken by name so the order never depends on
    /// dictionary iteration, which is not stable between runs.
    public static func precedes(_ a: UsageRow, _ b: UsageRow) -> Bool {
        a.total != b.total ? a.total > b.total : a.displayName < b.displayName
    }

    /// Splits a bucket's per-app totals into the two lists the popover shows.
    ///
    /// System rows are collapsed behind one expandable summary, so they are
    /// counted separately rather than competing with real apps for space.
    public static func partition(
        apps: [String: AppTotals],
        lastActivity: [String: Date],
        now: Date,
        activityWindow: TimeInterval = UsageRow.activityWindow
    ) -> (apps: [UsageRow], system: [UsageRow], systemTotal: Int64) {

        var appRows: [UsageRow] = []
        var systemRows: [UsageRow] = []
        var systemTotal: Int64 = 0

        for (key, totals) in apps {
            let active = lastActivity[key].map {
                now.timeIntervalSince($0) < activityWindow
            } ?? false
            let row = UsageRow(id: key,
                               displayName: totals.displayName,
                               bytesIn: totals.bytesIn,
                               bytesOut: totals.bytesOut,
                               bundlePath: totals.bundlePath,
                               isSystem: totals.isSystem,
                               isActive: active)
            if totals.isSystem {
                systemRows.append(row)
                systemTotal += row.total
            } else {
                appRows.append(row)
            }
        }

        return (appRows.sorted(by: precedes), systemRows.sorted(by: precedes), systemTotal)
    }
}

/// Keeps the popover list from reshuffling under the pointer.
///
/// Re-sorting live would make a row you are reaching for slide away as its
/// total changes. So the order is captured once, held for as long as the
/// popover stays open, and thrown away on close — see `reset()`.
public struct RowOrder {

    /// Row ids in the order they were first shown. Nil means nothing captured
    /// yet, so the next `apply` sorts freely and freezes the result.
    private var frozen: [String]?

    public init() {}

    /// Drops the captured order so the next `apply` sorts by size again.
    public mutating func reset() {
        frozen = nil
    }

    /// Sorts by total descending on the first call, then preserves that order.
    /// Rows appearing later are appended in size order rather than being slotted
    /// into the middle, which would push the existing rows down.
    public mutating func apply(to input: [UsageRow]) -> [UsageRow] {
        let sorted = input.sorted(by: UsageRow.precedes)

        guard let order = frozen else {
            frozen = sorted.map(\.id)
            return sorted
        }

        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() { rank[id] = index }

        let known = sorted.filter { rank[$0.id] != nil }
                          .sorted { rank[$0.id]! < rank[$1.id]! }
        let fresh = sorted.filter { rank[$0.id] == nil }
        if !fresh.isEmpty { frozen = order + fresh.map(\.id) }

        return known + fresh
    }
}

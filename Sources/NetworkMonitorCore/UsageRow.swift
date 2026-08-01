import Foundation

/// One row in the popover list.
public struct UsageRow: Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let bytesIn: Int64
    public let bytesOut: Int64
    public let bundlePath: String?
    public let isSystem: Bool
    /// Moved bytes within the last couple of seconds. True for a parent when
    /// either it or any of its children is active — the dot answers "is this app
    /// on the network", and a process it launched counts.
    public let isActive: Bool
    /// Processes this app launched that live outside its bundle, biggest first.
    /// Empty for all but a handful of rows.
    public let children: [UsageRow]

    /// Bytes billed to this process alone.
    public var ownTotal: Int64 { bytesIn + bytesOut }

    /// What the row displays: this app and everything it started.
    ///
    /// Combined rather than own-only so the visible rows still sum to the
    /// headline. A child's bytes have to be counted exactly once, and counting
    /// them in the parent is what lets the breakdown stay hidden by default.
    public var total: Int64 { ownTotal + children.reduce(0) { $0 + $1.total } }

    public var hasChildren: Bool { !children.isEmpty }

    public init(id: String, displayName: String, bytesIn: Int64, bytesOut: Int64,
                bundlePath: String?, isSystem: Bool, isActive: Bool,
                children: [UsageRow] = []) {
        self.id = id
        self.displayName = displayName
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.bundlePath = bundlePath
        self.isSystem = isSystem
        self.isActive = isActive
        self.children = children
    }
}

extension UsageRow {

    /// Default window in which an app must have moved bytes to count as active.
    ///
    /// Matches `PowerProfile.performance`. On battery the caller passes a longer
    /// one, because the dot must not blink off between samples that are further
    /// apart — see `PowerProfile.activityWindow`.
    public static let activityWindow: TimeInterval = 2.0

    /// How many child rows an app shows before the tail is rolled up.
    ///
    /// The breakdown answers "which part of this app is using the network", and
    /// that is answered by the few processes actually moving bytes. A build tool
    /// launching a dozen short-lived helpers would otherwise turn one row into a
    /// wall of them, which is the thing the System group already exists to
    /// prevent. The remainder is summed into a single "Other" row rather than
    /// dropped, so the children still add up to the parent.
    public static let maxChildrenShown = 4

    /// Biggest first; ties broken by name so the order never depends on
    /// dictionary iteration, which is not stable between runs.
    public static func precedes(_ a: UsageRow, _ b: UsageRow) -> Bool {
        a.total != b.total ? a.total > b.total : a.displayName < b.displayName
    }

    /// Sorts children biggest first and folds everything past the cap into one
    /// "Other" row, so a breakdown stays a summary rather than a process list.
    ///
    /// The tail is summed, never discarded: the children have to keep adding up
    /// to the parent's total, which is what makes the whole list reconcile with
    /// the headline.
    static func rollUp(_ children: [UsageRow], parentKey: String) -> [UsageRow] {
        let sorted = children.sorted(by: precedes)
        guard sorted.count > maxChildrenShown else { return sorted }

        let shown = sorted.prefix(maxChildrenShown - 1)
        let rest = sorted.dropFirst(maxChildrenShown - 1)
        let other = UsageRow(
            id: "\(parentKey)\u{1}\u{1}other",
            displayName: "Other (\(rest.count))",
            bytesIn: rest.reduce(0) { $0 + $1.bytesIn },
            bytesOut: rest.reduce(0) { $0 + $1.bytesOut },
            bundlePath: nil,
            isSystem: false,
            isActive: rest.contains(where: \.isActive))
        return Array(shown) + [other]
    }

    /// Splits a bucket's per-app totals into the two lists the popover shows,
    /// nesting adopted processes under the app that launched them.
    ///
    /// System rows are collapsed behind one expandable summary, so they are
    /// counted separately rather than competing with real apps for space.
    ///
    /// A parent named by a child but holding no traffic of its own still gets a
    /// row, synthesised from the child's `ParentApp`. Otherwise a terminal whose
    /// only network activity is the dev server it started would leave that
    /// server with nowhere to nest.
    public static func partition(
        apps: [String: AppTotals],
        lastActivity: [String: Date],
        now: Date,
        activityWindow: TimeInterval = UsageRow.activityWindow
    ) -> (apps: [UsageRow], system: [UsageRow], systemTotal: Int64) {

        func isActive(_ key: String) -> Bool {
            lastActivity[key].map { now.timeIntervalSince($0) < activityWindow } ?? false
        }
        func leaf(_ key: String, _ totals: AppTotals) -> UsageRow {
            UsageRow(id: key,
                     displayName: totals.displayName,
                     bytesIn: totals.bytesIn,
                     bytesOut: totals.bytesOut,
                     bundlePath: totals.bundlePath,
                     isSystem: totals.isSystem,
                     isActive: isActive(key))
        }

        var topLevel: [String: UsageRow] = [:]
        var systemRows: [UsageRow] = []
        var systemTotal: Int64 = 0
        var childrenByParent: [String: [UsageRow]] = [:]
        var parentsByKey: [String: ParentApp] = [:]

        for (key, totals) in apps {
            if totals.isSystem {
                let row = leaf(key, totals)
                systemRows.append(row)
                systemTotal += row.total
            } else if let parent = totals.parent {
                childrenByParent[parent.key, default: []].append(leaf(key, totals))
                parentsByKey[parent.key] = parent
            } else {
                topLevel[key] = leaf(key, totals)
            }
        }

        var appRows: [UsageRow] = []
        for (key, row) in topLevel where childrenByParent[key] == nil {
            appRows.append(row)
        }
        for (parentKey, children) in childrenByParent {
            let sortedChildren = rollUp(children, parentKey: parentKey)
            if let existing = topLevel[parentKey] {
                appRows.append(UsageRow(id: existing.id,
                                        displayName: existing.displayName,
                                        bytesIn: existing.bytesIn,
                                        bytesOut: existing.bytesOut,
                                        bundlePath: existing.bundlePath,
                                        isSystem: false,
                                        isActive: existing.isActive
                                            || sortedChildren.contains(where: \.isActive),
                                        children: sortedChildren))
            } else if let parent = parentsByKey[parentKey] {
                appRows.append(UsageRow(id: parent.key,
                                        displayName: parent.displayName,
                                        bytesIn: 0, bytesOut: 0,
                                        bundlePath: parent.bundlePath,
                                        isSystem: false,
                                        isActive: sortedChildren.contains(where: \.isActive),
                                        children: sortedChildren))
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

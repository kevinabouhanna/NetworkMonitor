import Foundation

/// The rows a list opened by itself (#593), so it can close them again: the
/// row left after choosing it, or a row shown only because what's inside it
/// matched a search. A row the person opens or closes by hand is theirs from
/// then on, and stays as they left it.
///
/// Usage History, Connections and Ads and Trackers each keep two: one for
/// choosing, one for search.
public struct OpenedByItself: Equatable {
    public private(set) var ids: Set<String> = []
    /// Rows `openOnce` has opened since the last `close`, kept even after the
    /// person closes one, so a list read again doesn't open it again.
    private var seen: Set<String> = []

    public init() {}

    /// Opens `id` in `open`, unless it's open already (then it stays the
    /// person's).
    public mutating func open(_ id: String, in open: inout Set<String>) {
        guard !open.contains(id) else { return }
        open.insert(id)
        ids.insert(id)
    }

    /// Opens `id` the first time only: a row the person closed stays closed
    /// when the list is read again (every 30 s), until `close`.
    public mutating func openOnce(_ id: String, in open: inout Set<String>) {
        guard seen.insert(id).inserted else { return }
        self.open(id, in: &open)
    }

    /// Closes every row this opened.
    public mutating func close(in open: inout Set<String>) {
        open.subtract(ids)
        ids.removeAll()
        seen.removeAll()
    }

    /// The person opened or closed it by hand.
    public mutating func handOver(_ id: String) {
        ids.remove(id)
    }

    /// Forgets everything, as a window opening afresh does.
    public mutating func reset() {
        ids.removeAll()
        seen.removeAll()
    }

    /// Whether a row shows only because of what's inside it: its own name
    /// doesn't match the search, and one of its parts' does.
    public static func matchesInside(_ name: String, parts: [String], query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !name.localizedCaseInsensitiveContains(query) else { return false }
        return parts.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

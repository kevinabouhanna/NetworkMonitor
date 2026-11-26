import Combine
import Foundation

/// Keeps a window's period on the calendar (#770, #776), for Usage History,
/// Connections and Ads & Trackers alike. A period that held the present when
/// last looked at moves on with it at its boundary: Today becomes the new
/// day at midnight, and the current week, month or year the next one. A
/// period someone chose stays where it is, with only its relative heading
/// ("Yesterday") to change.
///
/// Checked at the day change, on each window's refresh timer, and when its
/// section is shown again; `now` is the clock, so tests can cross midnight.
public final class PeriodFollower {

    public enum Step: Equatable {
        /// The calendar moved the period on: show this one, with the old
        /// figures gone, since they'd read as the new period's.
        case moveOn(HistoryPeriod)
        /// It still holds the present, or the section came back: read it again.
        case reload
        /// A past period stays, but its relative heading may have changed.
        case retitle
        case none
    }

    public let now: () -> Date
    private let calendar: Calendar
    /// When the period was last shown or checked against the present.
    private var reference: Date
    private var dayChanges: AnyCancellable?

    public init(calendar: Calendar, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
        reference = now()
    }

    /// A period was put on screen. A new one, or one holding the present,
    /// is checked from now on; the same past period shown again (another
    /// filter) keeps its reference, so a period the calendar has just passed
    /// still moves on at the next check.
    public func shown(_ period: HistoryPeriod, changed: Bool) {
        let present = now()
        if changed || period.contains(present) { reference = present }
    }

    /// What to do with `period` now. `reopening`: the section shown again,
    /// which reads its period again even when it's a past one.
    public func check(_ period: HistoryPeriod, reopening: Bool = false) -> Step {
        let present = now()
        let previous = reference
        reference = present
        if !period.contains(present) && period.contains(previous) {
            return .moveOn(HistoryPeriod(scale: period.scale, containing: present, calendar: calendar))
        }
        if reopening || period.contains(present) { return .reload }
        if !calendar.isDate(present, inSameDayAs: previous) { return .retitle }
        return .none
    }

    /// Calls `action` on the main queue each time the calendar day changes,
    /// until `stopObserving()`.
    public func observeDayChanges(_ action: @escaping () -> Void) {
        dayChanges = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { _ in action() }
    }

    public func stopObserving() { dayChanges = nil }
}

import Foundation

/// How much time one view of the history covers.
public enum HistoryScale: String, CaseIterable, Identifiable {
    case day, week, month, year

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day:   return "Day"
        case .week:  return "Week"
        case .month: return "Month"
        case .year:  return "Year"
        }
    }

    /// The calendar unit a period of this scale spans.
    var component: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        case .year:  return .year
        }
    }

    /// The calendar unit one bar of the chart spans: hours across a day, days
    /// across a week or a month, months across a year.
    public var binComponent: Calendar.Component {
        switch self {
        case .day:           return .hour
        case .week, .month:  return .day
        case .year:          return .month
        }
    }

    /// The scale a bar opens into when clicked, if any. A day's hours are
    /// already the finest grain the history keeps.
    public var drillDown: HistoryScale? {
        switch self {
        case .day:           return nil
        case .week, .month:  return .day
        case .year:          return .month
        }
    }
}

/// One calendar day, week, month or year — the window a history view reports on.
///
/// Calendar-aligned rather than rolling ("the last 7 days"), the way Screen Time
/// and carriers both count: a period has a name you can step back through, and
/// "October" means the same bytes every time you look at it.
public struct HistoryPeriod: Equatable {
    public let scale: HistoryScale
    /// Half-open: `start` is included, `end` is the next period's start.
    public let interval: DateInterval

    public init(scale: HistoryScale, containing date: Date, calendar: Calendar = .current) {
        self.scale = scale
        // `dateInterval(of:for:)` only fails for a calendar that has no such
        // unit, which none of the four is in any calendar Foundation ships.
        self.interval = calendar.dateInterval(of: scale.component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    public var start: Date { interval.start }
    public var end: Date { interval.end }

    public func contains(_ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }

    /// The period `count` steps away: `-1` is the one before.
    public func shifted(by count: Int, calendar: Calendar = .current) -> HistoryPeriod {
        let moved = calendar.date(byAdding: scale.component, value: count, to: interval.start)
            ?? interval.start
        return HistoryPeriod(scale: scale, containing: moved, calendar: calendar)
    }

    /// One interval per bar, in order.
    ///
    /// Stepped by the calendar rather than by a fixed number of seconds, so a
    /// day that loses an hour to daylight saving has 23 bars and one that gains
    /// an hour has 25 — each the hour the clock actually showed.
    public func bins(calendar: Calendar = .current) -> [DateInterval] {
        var bins: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            guard let next = calendar.date(byAdding: scale.binComponent, value: 1, to: start),
                  next > start
            else { break }
            bins.append(DateInterval(start: start, end: min(next, interval.end)))
            start = next
        }
        return bins
    }

    /// How many whole or part days of this period have happened by `now`, for
    /// a daily average that does not divide this month's 10 days of use by 31.
    public func elapsedDays(now: Date, calendar: Calendar = .current) -> Int {
        let last = min(now, interval.end.addingTimeInterval(-1))
        guard last >= interval.start else { return 0 }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: interval.start),
                                           to: calendar.startOfDay(for: last)).day ?? 0
        return days + 1
    }

    /// "Today", "Last Week", "October 2026" — the name in the window's header.
    public func title(now: Date = Date(), calendar: Calendar = .current,
                      locale: Locale = .current) -> String {
        let current = HistoryPeriod(scale: scale, containing: now, calendar: calendar)
        let sameYear = calendar.component(.year, from: interval.start)
            == calendar.component(.year, from: now)

        switch scale {
        case .day:
            if current == self { return "Today" }
            if current.shifted(by: -1, calendar: calendar) == self { return "Yesterday" }
            return Self.format(interval.start, sameYear ? "EEEEMMMd" : "yMMMd", calendar, locale)
        case .week:
            if current == self { return "This Week" }
            if current.shifted(by: -1, calendar: calendar) == self { return "Last Week" }
            let formatter = DateIntervalFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateTemplate = sameYear ? "MMMd" : "yMMMd"
            let lastDay = interval.end.addingTimeInterval(-1)
            return formatter.string(from: interval.start, to: lastDay)
        case .month:
            return Self.format(interval.start, "MMMMy", calendar, locale)
        case .year:
            return Self.format(interval.start, "y", calendar, locale)
        }
    }

    static func format(_ date: Date, _ template: String,
                       _ calendar: Calendar, _ locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// Values for the chart's byte axis.
public enum HistoryAxis {

    /// Gridline values from zero to just past `maximum`, in round 1024-based
    /// units.
    ///
    /// Not left to Swift Charts, whose round numbers are decimal: a 3 GB peak
    /// gets lines at 1,000,000,000-byte steps, which this app's 1024-based
    /// labels print as "953.7 MB". Choosing the steps in the unit the labels
    /// use gives 0 / 1 / 2 / 3 / 4 GB.
    public static func ticks(forMaximum maximum: Int64, approximateCount: Int = 4) -> [Int64] {
        guard maximum > 0 else { return [0, 1024] }
        let (scaled, _) = ByteFormat.scale(Double(maximum))
        let unit = Double(maximum) / scaled
        let rough = scaled / Double(max(approximateCount, 1))
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2.0, 2.5, 5.0, 10.0]
            .map { $0 * magnitude }
            .first { $0 >= rough } ?? 10 * magnitude
        var ticks: [Int64] = [0]
        var value = 0.0
        while value < scaled {
            value += step
            ticks.append(Int64((value * unit).rounded()))
        }
        return ticks
    }

    /// An axis label: "2 GB" rather than "2.0 GB", and a decimal only where the
    /// step needs one.
    ///
    /// Every label on an axis is written in the unit of its top value, so a
    /// 1.5 GB axis reads 0.5 / 1 / 1.5 GB rather than switching to "512 MB"
    /// for its first line.
    public static func label(_ bytes: Int64, inUnitOf top: Int64) -> String {
        guard bytes > 0 else { return "0" }
        let (scaledTop, unit) = ByteFormat.scale(Double(max(top, bytes)))
        let value = Double(bytes) / (Double(max(top, bytes)) / scaledTop)
        if abs(value - value.rounded()) < 0.05 {
            return "\(Int(value.rounded())) \(unit)"
        }
        return String(format: "%.1f %@", value, unit)
    }
}

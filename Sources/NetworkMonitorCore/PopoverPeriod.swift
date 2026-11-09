import Foundation

/// The period the popover's numbers cover (#449): today, this week or this
/// month, calendar ones as in the windows, so a window opened from the
/// popover shows the same numbers. Year and all time are in the windows.
public enum PopoverPeriod: String, CaseIterable, Identifiable {
    case today, week, month

    public var id: String { rawValue }

    /// On the switch.
    public var label: String {
        switch self {
        case .today: return L("Today")
        case .week:  return L("Week")
        case .month: return L("Month")
        }
    }

    /// In a sentence or after a button's name: "Data, This week, 38 GB".
    public var phrase: String {
        switch self {
        case .today: return L("Today")
        case .week:  return L("This week")
        case .month: return L("This month")
        }
    }

    /// The windows' scale for the same period.
    public var scale: HistoryScale {
        switch self {
        case .today: return .day
        case .week:  return .week
        case .month: return .month
        }
    }

    public func period(containing now: Date, calendar: Calendar = .current) -> HistoryPeriod {
        HistoryPeriod(scale: scale, containing: now, calendar: calendar)
    }
}

/// What the popover's Data view lists (#449).
public enum PopoverDataGrouping: String, CaseIterable, Identifiable {
    case apps, networks
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .apps:     return L("Apps")
        case .networks: return L("Networks")
        }
    }
}

/// What the popover's Ads blocked view lists (#449).
public enum PopoverAdsGrouping: String, CaseIterable, Identifiable {
    case sites, apps
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .sites: return L("Sites")
        case .apps:  return L("Apps")
        }
    }
}

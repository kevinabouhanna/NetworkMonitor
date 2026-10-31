import AppKit
import SwiftUI

// What NetworkMonitor can do with the person's OK (#134), said as what they
// get rather than how it works. Each is a row with the button that turns it
// on: in the welcome window on first launch, and again where it's used, for
// anyone who said "not now" and changes their mind. Website names are in
// Settings › Connections and the Connections window, Wi-Fi names in
// Settings › General. Once on, neither is shown there: there's nothing to
// manage (#181).

/// The words, in one place, so every row says the same thing and a test can
/// keep them plain.
public enum SetupCopy {
    public static let welcome = "It lives in your menu bar: click it to see which apps are using the "
        + "internet. Two more things it can do, if you'd like:"
    public static let later = "Not now? You can turn these on later in Settings. Nothing leaves your Mac."

    public static let websitesTitle = "See which websites your apps visit"
    public static let websitesSummary = "Slack shows up as slack.com, not just as Amazon, whose computers it "
        + "runs on. It also lets you block any app, company or country."

    /// The same switch, offered in Settings › Hotspot for what it does there (#98).
    public static let hotspotUpdatesTitle = "Stop every app's updates on hotspots"
    public static let hotspotUpdatesSummary = "Not only the apps listed here: any app's updater is stopped "
        + "while you're on a hotspot. It turns on the same thing as seeing which websites your apps visit."
    public static let hotspotUpdatesOn = "Any app's updater is stopped while you're on a hotspot, "
        + "including ones listed as can't be paused when they update with a program of their own. "
        + "Choose Blocked in Connections to see them."

    public static let wifiTitle = "Know your Wi-Fi networks by name"
    public static let wifiSummary = "Usage History calls them Home and Office, not “Wi-Fi · 3f2a”. macOS "
        + "calls this Location, but NetworkMonitor never looks up where you are."

    // The steps name what macOS shows, word for word, so they can be followed.
    public static let websitesSteps = [
        "In System Settings, scroll down to Network Extensions, click ⓘ, and switch on NetworkMonitor.",
        "Click Allow when macOS asks.",
    ]
    public static let wifiStep = "In System Settings, switch on Location Services for NetworkMonitor."
    public static let needsApplications = "Move NetworkMonitor to your Applications folder, open it from "
        + "there, and try again."
    public static let failed = "It didn't turn on. Try again, or restart your Mac if it keeps happening."

    /// Everything the person reads before a step: what they get, never how.
    public static var plain: [String] {
        [welcome, later, websitesTitle, websitesSummary, hotspotUpdatesTitle, hotspotUpdatesSummary,
         hotspotUpdatesOn, wifiTitle, wifiSummary, needsApplications, failed]
    }
}

/// One of them: what it is and what you get, and on the right the button that
/// turns it on, or a word that says it's on.
struct PermissionRow<Trailing: View, Detail: View>: View {
    let symbol: String
    let title: String
    let summary: String
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

/// What macOS needs from the person, numbered, the one they're on in full
/// strength.
struct SetupSteps: View {
    let steps: [String]
    var current = 0
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if steps.count > 1 { Text("\(index + 1).").monospacedDigit() }
                    Text(step).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(index == current ? HierarchicalShapeStyle.primary : .secondary)
            }
            if let onOpenSettings {
                Button("Open System Settings", action: onOpenSettings)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 6)
    }
}

struct OnBadge: View {
    var body: some View {
        Label("On", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
    }
}

/// Website names: the content filter (#128), in the person's terms. Turned
/// off in System Settings, not here (#181).
struct WebsiteNamesRow: View {
    @ObservedObject var filter: FilterController
    /// What it's offered as: website names, or, in Settings › Hotspot, a stop
    /// to every app's updates there (#98).
    var symbol = "globe"
    var title = SetupCopy.websitesTitle
    var summary = SetupCopy.websitesSummary

    var body: some View {
        PermissionRow(symbol: symbol, title: title, summary: summary) {
            trailing
        } detail: {
            detail
        }
    }

    @ViewBuilder private var trailing: some View {
        switch filter.state {
        case .unavailable:
            EmptyView()
        case .off:
            Button("Turn On…") { filter.turnOn() }
        case .failed:
            Button("Try Again") { filter.turnOn() }
        case .needsApplicationsFolder:
            Button("Turn On…") {}.disabled(true)
        case .starting, .waitingForApproval, .confirming:
            ProgressView().controlSize(.small)
        case .on:
            OnBadge()
        }
    }

    @ViewBuilder private var detail: some View {
        switch filter.state {
        case .needsApplicationsFolder:
            SetupSteps(steps: [SetupCopy.needsApplications])
        case .waitingForApproval:
            SetupSteps(steps: SetupCopy.websitesSteps, current: 0, onOpenSettings: Self.openSystemSettings)
        case .confirming:
            SetupSteps(steps: SetupCopy.websitesSteps, current: 1)
        case .failed(let reason):
            SetupSteps(steps: [SetupCopy.failed]).help(reason)
        default:
            EmptyView()
        }
    }

    /// General › Login Items & Extensions, where Network Extensions is.
    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

/// Wi-Fi names: Location (#85), in the person's terms.
struct WiFiNamesRow: View {
    @ObservedObject var wifiNames: WiFiNames

    var body: some View {
        PermissionRow(symbol: "wifi", title: SetupCopy.wifiTitle, summary: SetupCopy.wifiSummary) {
            if wifiNames.access == .allowed {
                OnBadge()
            } else {
                // macOS asks once. Once it's been told no, only System Settings
                // can change that.
                Button("Turn On…") {
                    if !wifiNames.ask() { Self.openSystemSettings() }
                }
            }
        } detail: {
            if wifiNames.access == .denied {
                SetupSteps(steps: [SetupCopy.wifiStep])
            }
        }
    }

    static func openSystemSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:"
            + "com.apple.preference.security?Privacy_LocationServices")!)
    }
}

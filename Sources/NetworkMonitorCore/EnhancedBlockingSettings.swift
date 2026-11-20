import AppKit
import FirewallPolicy
import SwiftUI
import UniformTypeIdentifiers

/// Enhanced ad blocking's place in Settings › Ads (#685, as designed on
/// #256): its switch with the ⓘ, then while it's on, the apps it reaches and
/// whether macOS trusts its certificate yet.
struct EnhancedBlockingSection: View {
    @ObservedObject var enhanced: EnhancedBlockingController
    @ObservedObject var firewall: FirewallRules

    var body: some View {
        Section {
            ExplainedRow(L("Enhanced ad blocking"), Self.explanation) {
                Toggle(L("Enhanced ad blocking"), isOn: Binding(get: { enhanced.isOn }, set: { enhanced.setOn($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if enhanced.isOn {
                LabeledContent {
                    Button(L("Apps…")) { enhanced.showsApps = true }
                        .help(L("Choose the apps whose pages it removes ads from"))
                } label: {
                    Text(L("Apps"))
                    Text(appsSummary)
                }
                if enhanced.status == .needsApproval {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Waiting for your approval")).font(.system(size: 13, weight: .semibold))
                            Text(L("Nothing is opened until macOS trusts NetworkMonitor's certificate. Ads are still blocked by name, as before."))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 12)
                        Button(L("Try Again…")) { enhanced.tryAgain() }
                            .help(L("Ask macOS again to trust NetworkMonitor's certificate"))
                    }
                }
            }
        } footer: {
            SettingsFootnote(footnote)
        }
        .onAppear { enhanced.refresh() }
        .sheet(isPresented: $enhanced.asksToTurnOn) { EnhancedApprovalSheet(enhanced: enhanced) }
        .sheet(isPresented: $enhanced.showsApps) { EnhancedAppsSheet(enhanced: enhanced, firewall: firewall) }
    }

    private var footnote: String {
        switch enhanced.status {
        case .off:
            return L("Also removes ads inside pages and videos, in Safari and other browsers. Off until you switch it on.")
        case .preparing:
            return L("Getting ready: macOS may ask you to allow NetworkMonitor's proxy.")
        case .approving:
            return L("macOS is asking for your password, to trust NetworkMonitor's certificate.")
        case .needsApproval:
            return L("Also removes ads inside pages and videos, once macOS trusts its certificate.")
        case .on:
            return L("On. Banking, health, government and payment sites, and sites you Always Allow in Your rules, are never opened.")
        }
    }

    private var appsSummary: String {
        let reached = enhanced.apps.filter { AppNames.isInstalled($0) && enhanced.reaches($0) }.map(AppNames.name)
        var summary: String
        switch reached.count {
        case 0: summary = L("No apps")
        case 1: summary = reached[0]
        case 2: summary = L("%@ and %@", reached[0], reached[1])
        default: summary = L("%@, %@ and %@ more", reached[0], reached[1], String(reached.count - 2))
        }
        let alone = enhanced.leftAlone.count
        if alone == 1 { summary += " · " + L("1 app left alone") }
        if alone > 1 { summary += " · " + L("%@ apps left alone", String(alone)) }
        return summary
    }

    static var explanation: String {
        L("NetworkMonitor opens your browsers' secure connections on this Mac, removes the ads inside their pages, and passes them on. Nothing leaves your Mac. It needs a certificate it makes for this Mac only: its key never leaves the Mac, and both are removed when you switch this off. Banking, health, government and payment sites, and sites you Always Allow, are never opened. How: a transparent proxy and a root certificate made on this Mac (HTTPS filtering).")
    }
}

/// What switching it on means, said once each time it's switched on, before
/// macOS asks its own questions.
public struct EnhancedApprovalSheet: View {
    @ObservedObject var enhanced: EnhancedBlockingController

    public init(enhanced: EnhancedBlockingController) { self.enhanced = enhanced }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(L("Turn on Enhanced ad blocking?"))
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text(L("NetworkMonitor will open your browsers' secure connections on this Mac to remove the ads inside pages and videos, then pass them on."))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.points, id: \.self) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(L("Next, macOS asks you twice: to allow NetworkMonitor's proxy, and for your password, to trust the certificate."))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            HStack {
                Spacer()
                Button(L("Cancel")) { enhanced.cancelTurnOn() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Continue…")) { enhanced.confirmTurnOn() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    static var points: [String] {
        [L("It makes a certificate for this Mac only. Its key never leaves the Mac."),
         L("Banking, health, government and payment sites, and sites you Always Allow, are never opened."),
         L("An app that refuses the certificate is left alone from then on."),
         L("Switch it off any time: the certificate and its key are removed.")]
    }
}

/// The apps it reaches: the browsers that are here, the apps the person
/// added, and the apps left alone because they refused the certificate.
public struct EnhancedAppsSheet: View {
    @ObservedObject var enhanced: EnhancedBlockingController
    @ObservedObject var firewall: FirewallRules

    public init(enhanced: EnhancedBlockingController, firewall: FirewallRules) {
        self.enhanced = enhanced
        self.firewall = firewall
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Apps it reaches")).font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(L("Pages in these apps have their ads removed. Browsers are on by default."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, app in
                    if index > 0 { Divider() }
                    Toggle(isOn: Binding(get: { enhanced.reaches(app) }, set: { enhanced.setReaches(app, $0) })) {
                        HStack {
                            Text(AppNames.name(app))
                            Spacer()
                            Text(EnhancedBlocking.browserApps.contains(app) ? L("Browser") : L("Added by you"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            Button(L("Add App…"), action: addApp)
                .help(L("Choose an app whose pages it removes ads from too"))
            if !enhanced.leftAlone.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Left alone")).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text(L("These apps refused NetworkMonitor's certificate (they only trust their own), so their connections are never opened. Their ads are still blocked by name."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(enhanced.leftAlone, id: \.self) { app in
                        HStack {
                            Text(AppNames.name(app))
                            Spacer()
                            Button(L("Try Again")) { enhanced.forgetLeftAlone(app) }
                                .help(L("Open this app's connections again, until it refuses the certificate"))
                                .accessibilityLabel(L("Try Again: %@", AppNames.name(app)))
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(L("Done")) { enhanced.showsApps = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// The browsers that are here, then the apps added.
    private var shown: [String] {
        enhanced.apps.filter { !EnhancedBlocking.browserApps.contains($0) || AppNames.isInstalled($0) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        enhanced.setReaches(id, true)
    }
}

/// Apps by bundle identifier: their name as the Finder shows it, and
/// whether they're on this Mac.
enum AppNames {
    /// Looked up once a minute at most: Settings asks on every redraw.
    private static var cache: [String: (url: URL?, at: Date)] = [:]

    static func url(_ id: String) -> URL? {
        if let kept = cache[id], Date().timeIntervalSince(kept.at) < 60 { return kept.url }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        cache[id] = (url, Date())
        return url
    }

    static func isInstalled(_ id: String) -> Bool { url(id) != nil }

    static func name(_ id: String) -> String {
        guard let url = url(id) else { return known[id] ?? id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// For an app that isn't here.
    static let known: [String: String] = [
        "com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome", "com.google.Chrome.canary": "Google Chrome Canary",
        "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "Brave Browser", "company.thebrowser.Browser": "Arc",
        "com.operasoftware.Opera": "Opera", "com.vivaldi.Vivaldi": "Vivaldi",
    ]
}

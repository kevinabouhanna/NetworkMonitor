import AppKit
import SwiftUI

/// The welcome window (#134): on first launch, hello, and what NetworkMonitor
/// can do with the person's OK, each a button away. Permissions belong to
/// setting an app up, as they do in most Mac apps that need them, not to a
/// switch in Settings that says how it works.
public enum Welcome {
    public static let shownKey = "welcomeShown"

    /// Once, and only when there's something to offer: an install whose
    /// permissions are all given already has nothing to be welcomed to.
    public static func shouldShow(shown: Bool, filter: FilterController.State, wifi: WiFiNames.Access) -> Bool {
        guard !shown else { return false }
        let offersWebsites = filter != .unavailable && filter != .on
        return offersWebsites || wifi != .allowed
    }
}

public final class WelcomeWindowController {
    public let window: NSWindow

    public init(filter: FilterController, wifiNames: WiFiNames) {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "Welcome to NetworkMonitor"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Nothing to minimise or zoom: it's read once and closed.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingController(rootView: WelcomeView(filter: filter, wifiNames: wifiNames) {
            [weak window] in window?.performClose(nil)
        })
        // Grows when a row shows its steps, and shrinks back.
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        // Its real size before it's centred.
        window.setContentSize(host.view.fittingSize)
        self.window = window
    }
}

struct WelcomeView: View {
    @ObservedObject var filter: FilterController
    @ObservedObject var wifiNames: WiFiNames
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Welcome to NetworkMonitor")
                    .font(.system(size: 20, weight: .semibold))
                Text(SetupCopy.welcome)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 14) {
                if filter.state != .unavailable {
                    WebsiteNamesRow(filter: filter)
                    Divider()
                }
                WiFiNamesRow(wifiNames: wifiNames)
            }
            .padding(16)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
            .padding(.horizontal, 24)
            .padding(.top, 20)

            HStack(spacing: 12) {
                Text(SetupCopy.later)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .padding(.top, 28)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

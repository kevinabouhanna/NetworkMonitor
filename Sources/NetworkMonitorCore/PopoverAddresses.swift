import AppKit
import SwiftUI

/// Whether Show's question is open. Not `@State`; see `SettingsPaneState`.
final class PopoverAddressesState: ObservableObject {
    @Published var confirming = false
}

/// The Mac's addresses in the popover's Network view (#803): this Mac's on
/// the network, the internet address once you've said it may be asked for,
/// and where that is.
struct PopoverAddresses: View {
    @ObservedObject var addresses: InternetAddress
    /// The VPN or proxy every app's traffic goes through, by name (#356).
    let tunnel: String?
    @StateObject private var ui = PopoverAddressesState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(L("This Mac"), help: L("This Mac's address on the network it's on")) {
                if let local = addresses.local {
                    address(local, copy: L("Copy this Mac's address"))
                } else {
                    Text(L("No address")).foregroundStyle(.secondary)
                }
            }
            if ui.confirming {
                question
            } else {
                row(L("Internet"), help: L("The address websites see")) { internet }
            }
            if case .found(let answer) = addresses.state, let place = answer.place() {
                row(L("Location"), help: L("Where the internet address is, from the country data already in the app")) {
                    Text(place).lineLimit(1).truncationMode(.tail)
                }
            }
            if let tunnel {
                Text(L("Through %@: websites see its address, not this network's.", tunnel))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var internet: some View {
        switch addresses.state {
        case .found(let answer):
            address(answer.address, copy: L("Copy the internet address"))
        case .asking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L("Asking…")).foregroundStyle(.secondary)
            }
        case .failed:
            HStack(spacing: 6) {
                Text(L("Couldn't find out")).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button(L("Try Again")) { addresses.show() }.controlSize(.mini)
            }
        case .notHere:
            Text(L("Not asked on a hotspot or in Low Data Mode"))
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        case .notAsked:
            HStack {
                Spacer(minLength: 4)
                Button(L("Show")) {
                    if addresses.isEnabled { addresses.show() } else { ui.confirming = true }
                }
                .controlSize(.mini)
                .help(L("Show the address websites see"))
                .accessibilityLabel(L("Show the internet address"))
            }
        }
    }

    /// Show's first click: what's asked, and of whom, before anything is.
    private var question: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Only an outside service can tell the address websites see. Ask Cloudflare's 1.1.1.1 now, and again when you change networks? It learns that address and nothing else."))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L("Not Now")) { ui.confirming = false }.controlSize(.small)
                Button(L("Ask")) {
                    ui.confirming = false
                    addresses.show()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func row<Content: View>(_ title: String, help: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .help(help)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 18)
    }

    private func address(_ text: String, copy: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copy)
            .accessibilityLabel(copy)
        }
    }
}

extension InternetAddress.Answer {
    /// "🇩🇪 Germany · Deutsche Telekom", or as much of it as is known.
    public func place(locale: Locale = .current) -> String? {
        let country = self.country.map { code in
            [ConnectionsReport.flag(code), ConnectionsReport.countryName(code, locale: locale)]
                .compactMap { $0 }.joined(separator: " ")
        }
        let parts = [country, provider].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

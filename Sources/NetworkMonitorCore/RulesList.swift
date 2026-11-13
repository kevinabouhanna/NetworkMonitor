import AppKit
import SwiftUI

// Your rules, where you made them (#592): Connections and Ads and Trackers
// each have a Rules list beside what they show, made of the same parts, so a
// rule reads and changes the same way in both. Every action is a control you
// can see and read (Kevin, 13 Nov 2026): what the rule does is a menu
// that changes it, Show goes to what it covers, and − removes it. A click on
// the row itself does nothing.

/// One choice in a rule's menu: Block, Block on Hotspots, Always Allow.
struct RuleChoice: Identifiable {
    let title: String
    let isCurrent: Bool
    let action: () -> Void
    var id: String { title }
}

/// One rule, as a Rules list shows it.
struct RuleRowModel: Identifiable {
    enum Icon {
        case symbol(String)
        case image(NSImage)
    }

    let id: String
    let icon: Icon
    /// What it's about: Google, Safari, example.com.
    let title: String
    /// What kind of thing, and for which app or network: "Company · for Safari".
    let detail: String?
    /// What it did in the period: "Stopped 52 times", "94.9 MB let through".
    let activity: String?
    /// What it does: "Blocked", "Always allowed". The menu's title when it
    /// has choices, a word on its own when it hasn't.
    let state: String
    let tone: Tone
    let choices: [RuleChoice]
    /// "Show in Blocked", and what it does; nil where there's nothing to show.
    let show: (title: String, action: () -> Void)?
    /// What VoiceOver and the tooltip call the remove button.
    let removeTitle: String
    let removeHelp: String
    let remove: () -> Void

    enum Tone {
        case blocked, sometimes, allowed

        var color: Color {
            switch self {
            case .blocked:   return .red
            case .sometimes: return .orange
            case .allowed:   return .green
            }
        }
    }
}

/// A group of rules: Blocked, Always allowed…
struct RuleSection: Identifiable {
    let id: String
    let title: String
    let note: String
    let rows: [RuleRowModel]
}

/// The list: each section's heading and note, then its rules; empty
/// sections aren't shown. With none at all, `empty` says how to make one.
struct RulesList<Empty: View>: View {
    let sections: [RuleSection]
    /// The window's own margin, inside the list's scrolling.
    var inset: CGFloat = 20
    @ViewBuilder let empty: Empty

    var body: some View {
        if sections.allSatisfy(\.rows.isEmpty) {
            empty.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections.filter { !$0.rows.isEmpty }) { section in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(section.title)
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Text(String(section.rows.count))
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Text(section.note).font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            .padding(.bottom, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(section.rows) { RuleRow(row: $0) }
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.vertical, 14)
            }
        }
    }
}

/// A rule: its icon, what it's about and what kind, what it did, then its
/// controls. The same in both windows.
struct RuleRow: View {
    let row: RuleRowModel

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(1).truncationMode(.middle)
                if let detail = row.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            if let activity = row.activity {
                Text(activity)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            state
                .frame(width: RulesMetrics.stateWidth, alignment: .leading)
            Group {
                if let show = row.show {
                    Button(L("Show"), action: show.action)
                        .buttonStyle(.link)
                        .help(show.title)
                        .accessibilityLabel(L("%@: %@", show.title, row.title))
                } else {
                    Color.clear.accessibilityHidden(true)
                }
            }
            .frame(width: RulesMetrics.showWidth, alignment: .leading)
            Button(action: row.remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(row.removeHelp)
            .accessibilityLabel(row.removeTitle)
        }
        .font(.system(size: 13))
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
        .padding(.vertical, 1)
    }

    @ViewBuilder private var icon: some View {
        switch row.icon {
        case .image(let image):
            Image(nsImage: image).resizable().frame(width: 18, height: 18).accessibilityHidden(true)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }

    /// What the rule does, in its colour: a menu that changes it, or the
    /// word alone when there's nothing to change it to.
    @ViewBuilder private var state: some View {
        let mark = Circle().fill(row.tone.color).frame(width: 7, height: 7).accessibilityHidden(true)
        if row.choices.isEmpty {
            HStack(spacing: 5) {
                mark
                Text(row.state).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 12))
        } else {
            HStack(spacing: 5) {
                mark
                Menu {
                    ForEach(row.choices) { choice in
                        Toggle(choice.title, isOn: Binding(get: { choice.isCurrent },
                                                           set: { if $0 { choice.action() } }))
                    }
                } label: {
                    Text(row.state)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.system(size: 12))
                .help(L("Change what this rule does"))
                .accessibilityLabel(L("Change the rule for %@", row.title))
                .accessibilityValue(row.state)
            }
        }
    }
}

/// The bar above a Rules list (#592): a site, which apps, and what to do
/// with it. The same in both windows, with each window's own explanation.
struct AddRuleBar<Trailing: View>: View {
    @Binding var site: String
    let app: AdsViewModel.RuleApp?
    let knownApps: [AdsViewModel.RuleApp]
    let error: String?
    let explanation: String
    let onApp: (AdsViewModel.RuleApp?) -> Void
    let onBlock: () -> Void
    let onAllow: () -> Void
    let onEdit: () -> Void
    @ViewBuilder let trailing: Trailing
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                TextField(L("A site, like example.com"), text: $site)
                    .accessibilityLabel(L("Site"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200, maxWidth: 280)
                    .onSubmit(onBlock)
                Menu(app.map { L("In %@", $0.name) } ?? L("In Every App")) {
                    Button(L("Every App")) { onApp(nil) }
                    if !knownApps.isEmpty { Divider() }
                    ForEach(knownApps) { app in Button(app.name) { onApp(app) } }
                    Divider()
                    Button(L("Choose an App…")) {
                        if let app = AddRuleBarPicker.pickApp() { onApp(app) }
                    }
                }
                .fixedSize()
                .accessibilityLabel(L("Which apps"))
                // Named for what they do to the site: "Block" alone is also an
                // SF Symbol's name, which says nothing of what it acts on.
                Button(L("Block"), action: onBlock)
                    .accessibilityLabel(L("Block the site"))
                Button(L("Always Allow"), action: onAllow)
                    .accessibilityLabel(L("Always allow the site"))
                RowInfoButton(help: explanation, state: info) { Text(explanation) }
                Spacer(minLength: 0)
                trailing
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { info.isHovering = $0 }
        .onChange(of: site) { _ in onEdit() }
    }
}

enum AddRuleBarPicker {
    /// An app chosen in a panel, keyed as Connections keys apps.
    static func pickApp() -> AdsViewModel.RuleApp? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return AdsViewModel.ruleApp(at: url)
    }
}

/// The line under a Rules list that points at the other window's (#592):
/// "Ads and Trackers has 4 rules of its own. Show Them".
struct OtherRulesLine: View {
    let text: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            Button(L("Show Them"), action: action)
                .buttonStyle(.link)
                .font(.system(size: 12))
                .accessibilityLabel(L("Show them: %@", text))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

enum RulesMetrics {
    /// The rule's menu, wide enough for "Blocked on hotspots" in either
    /// language, so the Show buttons line up.
    static let stateWidth: CGFloat = 170
    static let showWidth: CGFloat = 44
}

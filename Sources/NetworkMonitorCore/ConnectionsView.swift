import AppKit
import FirewallPolicy
import ServerDirectory
import SwiftUI

/// The Connections window: which companies, countries and servers your apps
/// talk to.
///
/// One column, read top to bottom like History: what it's grouped by and which
/// period, what it's narrowed to, how much, when, and then who. The list
/// doubles as the filter: a row inside a group narrows the window to it, and
/// its chip undoes that.
public struct ConnectionsView: View {
    @ObservedObject var model: ConnectionsViewModel
    @ObservedObject var firewall: FirewallRules

    public init(model: ConnectionsViewModel) {
        self.model = model
        self.firewall = model.firewall
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 14) {
                if model.offersWebsiteNames {
                    WebsiteNamesOffer(filter: model.filter) { model.offersWebsiteNames = false }
                }
                scopeBar
                header
                ConnectionsTimeline(model: model)
                switch shownLayout(width: geometry.size.width) {
                case .list:
                    list
                case .map:
                    ConnectionsMap(model: model)
                case .both:
                    HStack(alignment: .top, spacing: 14) {
                        list.frame(width: (geometry.size.width - 40) * 0.46)
                        ConnectionsMap(model: model)
                    }
                }
                Divider()
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .frame(minWidth: ConnectionsMetrics.minWidth, minHeight: ConnectionsMetrics.minHeight)
        .background(periodShortcuts)
    }

    /// Both needs room for the list and a map worth reading; narrower, it's the
    /// list, and Both comes back when the window is widened.
    private func shownLayout(width: CGFloat) -> ConnectionsViewModel.Layout {
        model.layout == .both && width < ConnectionsMetrics.bothMinWidth ? .list : model.layout
    }

    // MARK: Scope

    /// What the list is grouped by and narrowed to, in one labelled row under
    /// the toolbar. The view, the period and search are in the toolbar itself
    /// (`ConnectionsWindowController`).
    private var scopeBar: some View {
        HStack(spacing: 10) {
            LabelledControl("Group by") {
                Picker("Group by", selection: Binding(get: { model.grouping }, set: { model.grouping = $0 })) {
                    ForEach(ConnectionsGrouping.allCases) { Text($0.label).tag($0) }
                }
                .help("Group the list by company, app or country. A row inside a group narrows "
                      + "the window to it.")
            }
            // What was blocked (#114), once there's a filter to block anything.
            if model.filter.state != .unavailable {
                LabelledControl("Show") {
                    Picker("Show", selection: Binding(get: { model.measure }, set: { model.measure = $0 })) {
                        Text("Traffic").tag(ServerMeasure.bytes)
                        Text("Blocked").tag(ServerMeasure.blocked)
                    }
                    .help("What your apps sent and received, or the connections that were blocked")
                }
            }
            if model.spanTitle != nil || !model.chips.isEmpty {
                Divider().frame(height: 16)
                HStack(spacing: 6) {
                    if let span = model.spanTitle {
                        FilterChip(label: span, onClear: model.clearSpan)
                    }
                    ForEach(model.chips) { item in
                        FilterChip(label: item.title, onClear: { model.clear(item.dimension) })
                    }
                }
            }
            Spacer(minLength: 12)
            // All, Wi-Fi and Hotspot say what they are; no label needed.
            Picker("Networks", selection: Binding(get: { model.kind }, set: { model.setKind($0) })) {
                Text("All").tag(NetworkFingerprint.Kind?.none)
                ForEach([NetworkFingerprint.Kind.wifi, .hotspot], id: \.self) { kind in
                    Text(kind.historyLabel).tag(NetworkFingerprint.Kind?.some(kind))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            .help("Every connection, Wi-Fi only, or hotspots only")
        }
        .frame(height: 24)
    }

    // MARK: Header

    /// When, then how much, then who.
    private var header: some View {
        let summary = model.summary
        return PeriodHeading(
            title: model.spanTitle.map { "\(model.title), \($0)" } ?? model.title,
            figure: model.measure == .bytes ? ByteFormat.bytes(summary.total) : summary.total.formatted(),
            caption: model.measure == .bytes ? "to and from servers"
                : (summary.total == 1 ? "connection blocked" : "connections blocked"),
            details: [PeriodHeading.count(summary.companies, "company", "companies"),
                      PeriodHeading.count(summary.countries, "country", "countries"),
                      PeriodHeading.count(summary.apps, "app", "apps"),
                      PeriodHeading.count(summary.servers, "server", "servers")])
    }

    /// ⌘← and ⌘→ step through periods, as in History. The toolbar's arrows do
    /// the same with the pointer.
    private var periodShortcuts: some View {
        ZStack {
            Button("Previous") { model.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!model.canStepBack)
            Button("Next") { model.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!model.canStepForward)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.groups.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(emptyTitle)
                    .font(.system(size: 13, weight: .medium))
                Text(emptyDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let largest = model.groups.first?.item.total ?? 1
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // One element per group, its rows inside it. Flattened, the
                    // same company or country under two apps gave the lazy stack
                    // two rows with one identity, and it left a blank where one
                    // group's sections should have been.
                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            groupRows(group, largest: largest)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var emptyTitle: String {
        if !model.hasLoaded { return "Loading…" }
        if !model.search.isEmpty || !model.chips.isEmpty { return "Nothing matches" }
        let when = model.span == nil ? model.scale.label.lowercased() : "span"
        return model.measure == .blocked ? "Nothing blocked in this \(when)" : "No connections in this \(when)"
    }

    private var emptyDetail: String {
        if !model.hasLoaded { return "" }
        if !model.search.isEmpty || !model.chips.isEmpty { return "Clear the search or a chip to see more." }
        if model.measure == .blocked {
            return "Right-click a company, app, country or server under Traffic to block it."
        }
        return "Connections are recorded from this version on, while NetworkMonitor is running."
    }

    @ViewBuilder
    private func groupRows(_ group: ConnectionsGroup, largest: Int64) -> some View {
        let isOpen = model.expanded.contains(group.id)
        ConnectionsRow(item: group.item, subtitle: subtitle(for: group.item),
                       icon: model.icon(for: group.item), fraction: fraction(group.item.total, of: largest),
                       indent: 0, disclosure: isOpen, rule: firewall.rule(for: group.item)?.action,
                       onToggleDisclosure: { model.toggle(group.id) },
                       onSelect: { model.toggle(group.id) },
                       help: isOpen ? "Click to close" : "Click to see its \(sectionNames(group))",
                       format: model.format)
            .contextMenu { ruleMenu(for: group.item) }
        if isOpen {
            ForEach(group.sections.filter { !$0.items.isEmpty }) { section in
                sectionRows(section, in: group)
            }
        }
    }

    @ViewBuilder
    private func sectionRows(_ section: ConnectionsGroup.Section, in group: ConnectionsGroup) -> some View {
        let sectionID = group.id + "/" + section.id
        let showingAll = model.showingAll.contains(sectionID)
        let shown = showingAll ? section.items : Array(section.items.prefix(ConnectionsViewModel.sectionPreview))
        let largest = section.items.first?.total ?? 1
        Text("\(section.dimension.plural) · \(section.items.count)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 38)
            .padding(.top, 6)
            .padding(.bottom, 2)
        ForEach(shown) { item in
            ConnectionsRow(item: item, subtitle: subtitle(for: item), icon: model.icon(for: item),
                           fraction: fraction(item.total, of: largest), indent: 1, disclosure: nil,
                           rule: firewall.rule(for: item)?.action,
                           onToggleDisclosure: {}, onSelect: { model.narrow(to: item, in: group.item) },
                           help: "Click to see only \(item.title)", format: model.format)
                .contextMenu { ruleMenu(for: item) }
        }
        if section.items.count > shown.count {
            Button("Show all \(section.items.count)") { model.showingAll.insert(sectionID) }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .padding(.leading, 46)
                .padding(.vertical, 4)
        }
    }

    // MARK: Rules

    /// Right-click a row (#114): block it, block it on hotspots, or always
    /// allow it. The one it has is ticked. Not in a build without the filter,
    /// where nothing could enforce it.
    @ViewBuilder
    private func ruleMenu(for item: ConnectionsItem) -> some View {
        if FirewallRules.canHaveRule(item), model.filter.state != .unavailable {
            let current = firewall.rule(for: item)
            ForEach(RuleAction.allCases, id: \.self) { action in
                Toggle(Self.menuTitle(action, item.title), isOn: Binding(
                    get: { current?.action == action },
                    set: { isOn in
                        if isOn { model.setRule(action, for: item) } else if let current { firewall.remove(current) }
                    }))
            }
            if let current {
                Divider()
                Button("Remove Rule") { firewall.remove(current) }
            }
        }
    }

    static func menuTitle(_ action: RuleAction, _ title: String) -> String {
        switch action {
        case .block:           return "Block “\(title)”"
        case .blockOnHotspots: return "Block “\(title)” on Hotspots"
        case .allow:           return "Always Allow “\(title)”"
        }
    }

    private func subtitle(for item: ConnectionsItem) -> String? {
        item.dimension == .app ? model.subtitle(forApp: item) : item.subtitle
    }

    private func sectionNames(_ group: ConnectionsGroup) -> String {
        group.sections.map { $0.dimension.plural.lowercased() }.joined(separator: ", ")
    }

    private func fraction(_ bytes: Int64, of largest: Int64) -> Double {
        largest > 0 ? Double(bytes) / Double(largest) : 0
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Link(ServerDirectory.credit, destination: ServerDirectory.creditURL)
                .font(.system(size: 10))
            Text("·").foregroundStyle(.tertiary)
            Text("Everything is named on this Mac: nothing is looked up online.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
    }
}

/// One row: a group at the top level, or an item inside one.
/// Website names, offered where they'd show (#134), while they're off: a
/// slim row above the list, closed for good with its ×.
private struct WebsiteNamesOffer: View {
    @ObservedObject var filter: FilterController
    let onClose: () -> Void

    var body: some View {
        switch filter.state {
        case .unavailable, .on:
            EmptyView()
        default:
            HStack(alignment: .top, spacing: 10) {
                WebsiteNamesRow(filter: filter)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close. Settings › Connections still has it.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// What a row's rule says, beside its name: red for blocked, orange for
/// blocked on hotspots, green for always allowed.
struct RuleBadge: View {
    let action: RuleAction

    var body: some View {
        Text(action.badge.uppercased())
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .fixedSize()
    }

    private var color: Color {
        switch action {
        case .block:           return .red
        case .blockOnHotspots: return .orange
        case .allow:           return .green
        }
    }
}

private struct ConnectionsRow: View {
    let item: ConnectionsItem
    let subtitle: String?
    let icon: NSImage?
    let fraction: Double
    let indent: Int
    /// nil for a row with nothing to open; otherwise whether it's open.
    let disclosure: Bool?
    /// The person's rule for it, if any (#114).
    let rule: RuleAction?
    let onToggleDisclosure: () -> Void
    let onSelect: () -> Void
    let help: String
    /// Bytes, or blocked connections (#114).
    var format: (Int64) -> String = { ByteFormat.bytes($0) }

    /// Not `@State`, which needs Xcode from the macOS 27 SDK on.
    @StateObject private var hover = HistoryRowHover()

    var body: some View {
        HStack(spacing: 8) {
            if indent > 0 { Spacer().frame(width: 22) }
            if let disclosure {
                Button(action: onToggleDisclosure) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(disclosure ? 90 : 0))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Spacer().frame(width: 14)
            }
            leading
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12))
                        .foregroundStyle(indent > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isHost {
                        Text("HOST")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18), in: Capsule())
                            .foregroundStyle(.secondary)
                            .help("A network that carries many companies' traffic")
                    }
                    if let rule { RuleBadge(action: rule) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 12)
            bar
                .frame(width: ConnectionsMetrics.rowBarWidth, alignment: .leading)
            Text(format(item.total))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: (subtitle?.isEmpty ?? true) ? 30 : 38)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hover.isHovering ? Color.secondary.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover.isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .help(help)
    }

    @ViewBuilder
    private var leading: some View {
        if let icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
        } else if let symbol = item.symbol {
            Text(symbol).font(.system(size: 14))
        } else {
            Image(systemName: systemSymbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var systemSymbol: String {
        switch item.dimension {
        case .company:
            if item.key == ConnectionsReport.unknownKey { return "questionmark.circle" }
            if item.key == ConnectionsReport.otherKey { return "ellipsis.circle" }
            return item.isHost ? "server.rack" : "building.2"
        case .app:     return "gearshape"
        case .country: return "globe"
        case .server:  return "point.3.connected.trianglepath.dotted"
        }
    }

    private var bar: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor.opacity(indent > 0 ? 0.55 : 0.85))
            .frame(width: max(3, ConnectionsMetrics.rowBarWidth * min(max(fraction, 0), 1)), height: 6)
    }
}

/// The period's traffic to servers, one bar per hour, day or month. Drag
/// across it, or click a bar, to narrow the list to that span.
private struct ConnectionsTimeline: View {
    @ObservedObject var model: ConnectionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                let bins = model.bins
                let largest = max(bins.map(\.bytes).max() ?? 0, 1)
                let width = geometry.size.width / CGFloat(max(bins.count, 1))
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(bins.enumerated()), id: \.element.id) { index, bin in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: index))
                            .frame(width: max(width - 2, 1),
                                   height: bin.bytes > 0
                                       ? max(2, geometry.size.height * CGFloat(Double(bin.bytes) / Double(largest)))
                                       : 1)
                            .frame(width: width, height: geometry.size.height, alignment: .bottom)
                            .help("\(HistoryFormat.binTitle(bin.interval, scale: model.scale)): "
                                  + model.format(bin.bytes))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let first = index(at: value.startLocation.x, width: width, count: bins.count)
                            let last = index(at: value.location.x, width: width, count: bins.count)
                            model.dragging = min(first, last)...max(first, last)
                        }
                        .onEnded { _ in
                            if let picked = model.dragging { model.pick(picked) }
                            model.dragging = nil
                        })
            }
            .frame(height: ConnectionsMetrics.timelineHeight)
            axis
        }
    }

    private var axis: some View {
        let bins = model.bins
        let marks = bins.isEmpty ? [] : Array(Set([0, bins.count / 2, bins.count - 1])).sorted()
        return HStack {
            ForEach(marks, id: \.self) { index in
                Text(HistoryFormat.axisLabel(bins[index].interval.start, scale: model.scale))
                if index != marks.last { Spacer() }
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private func index(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 0, width > 0 else { return 0 }
        return min(max(Int(x / width), 0), count - 1)
    }

    private func color(for index: Int) -> Color {
        let picked = model.dragging ?? model.span
        guard let picked else { return Color.accentColor.opacity(0.75) }
        return picked.contains(index) ? Color.accentColor : Color.secondary.opacity(0.3)
    }
}

enum ConnectionsMetrics {
    static let minWidth: CGFloat = 760
    static let minHeight: CGFloat = 520
    static let rowBarWidth: CGFloat = 140
    static let timelineHeight: CGFloat = 54
    /// Below this, Both shows the list alone.
    static let bothMinWidth: CGFloat = 900
}

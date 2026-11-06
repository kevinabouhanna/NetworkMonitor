import Charts
import UniformTypeIdentifiers
import FirewallPolicy
import SwiftUI

/// The Ads and Trackers window's content (#251): what the lists blocked in
/// the period, over time, by site and by app, and pausing. The period is in
/// the window's toolbar, as in Connections.
struct AdsView: View {
    @ObservedObject var model: AdsViewModel
    /// Not `@State`; see `SettingsPaneState`.
    @StateObject private var info = RowInfoState()

    var body: some View {
        VStack(spacing: 0) {
            if model.tab == .log {
                AdsLogView(model: model)
            } else if !model.isOn {
                off
            } else {
                header
                Divider()
                if model.report.total == 0 {
                    empty
                } else {
                    chart
                        .frame(height: AdsMetrics.chartHeight)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    Divider()
                    HStack(alignment: .top, spacing: 0) {
                        AdsList(title: "Sites", items: model.report.sites, total: model.report.total, model: model)
                        Divider()
                        AdsList(title: "Apps", items: model.report.apps, total: model.report.total, model: model)
                    }
                }
            }
        }
        .frame(minWidth: AdsMetrics.minWidth, minHeight: AdsMetrics.minHeight)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(model.report.total.formatted()) blocked")
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                    RowInfoButton(help: Self.explanation, state: info) { Text(Self.explanation) }
                }
                Text(model.title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onHover { info.isHovering = $0 }
            HStack(spacing: 14) {
                ForEach(model.report.lists, id: \.list) { entry in
                    HStack(spacing: 6) {
                        if let topic = BlocklistTopic(rawValue: entry.list) { ListTag(topic: topic) }
                        Text(AdsReport.title(ofList: entry.list)).foregroundStyle(.secondary)
                        Text(entry.count.formatted()).monospacedDigit()
                    }
                    .font(.system(size: 12))
                }
            }
            Spacer(minLength: 12)
            pause
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var pause: some View {
        if let until = model.pausedUntil {
            HStack(spacing: 8) {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Button("Resume") { model.resume() }
            }
        } else {
            Menu("Pause") {
                Button("For 1 Hour") { model.pause(for: 3600) }
                Button("Until Tomorrow") { model.pauseUntilTomorrow() }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Let ads through for a while, in every app")
        }
    }

    static let explanation = "Connections to sites on the lists you chose in Settings › Connections, stopped "
        + "before they started, in every app. NetworkMonitor reads only each connection's site name, from the "
        + "app or from the opening of a secure connection, never what's sent. Ads served from a site's own "
        + "servers, like YouTube's, can't be told apart from the site by name."

    // MARK: Chart

    private var chart: some View {
        let top = max(model.bins.map(\.count).max() ?? 0, 1)
        return Chart(model.bins) { bin in
            BarMark(x: .value("Time", bin.interval.start, unit: model.scale.binComponent),
                    y: .value("Blocked", bin.count))
                .foregroundStyle(Color.red.opacity(0.75))
                .cornerRadius(2)
        }
        .chartXScale(domain: model.period.start...model.period.end)
        .chartYScale(domain: 0...Double(top))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let count = value.as(Double.self) {
                        Text(Int64(count).formatted()).font(.system(size: 10)).monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: Empty and off

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Nothing blocked \(model.period.contains(Date()) ? "yet" : "in this period")")
                .font(.system(size: 14, weight: .medium))
            Text("Ads and trackers your apps try to reach show here as they're stopped.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var off: some View {
        VStack(spacing: 8) {
            Image(systemName: "shield.slash").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("Ad blocking is off").font(.system(size: 14, weight: .medium))
            Text("Turn it on to stop ads, trackers and malware sites in every app.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Turn On") { model.turnOn() }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sites or apps, most blocked first, each with a bar for its share.
private struct AdsList: View {
    let title: String
    let items: [AdsItem]
    let total: Int64
    let model: AdsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        AdsRow(item: item, icon: model.icon(for: item),
                               fraction: Double(item.count) / Double(max(items.first?.count ?? 1, 1)))
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AdsRow: View {
    let item: AdsItem
    let icon: NSImage?
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    ForEach(item.lists, id: \.self) { list in
                        if let topic = BlocklistTopic(rawValue: list) { ListTag(topic: topic) }
                    }
                }
                if let detail = item.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            GeometryReader { geometry in
                Capsule().fill(Color.red.opacity(0.6))
                    .frame(width: max(2, geometry.size.width * fraction), height: 4)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: AdsMetrics.rowBarWidth, height: 20)
            Text(item.count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(item.detail.map { "\(item.title): \($0)" } ?? item.title)
    }
}

enum AdsMetrics {
    static let minWidth: CGFloat = 760
    static let minHeight: CGFloat = 480
    static let chartHeight: CGFloat = 120
    static let rowBarWidth: CGFloat = 90
    static let logTime: CGFloat = 76
    static let logApp: CGFloat = 170
    static let logDecision: CGFloat = 76
    static let logWhy: CGFloat = 210
}

// MARK: - Log (#252)

/// Every connection the filter decided, newest first, with what decided it,
/// and a rule from any row.
struct AdsLogView: View {
    @ObservedObject var model: AdsViewModel

    var body: some View {
        let entries = model.logEntries
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Show", selection: $model.logShow) {
                    ForEach(AdsLog.Show.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search apps, sites and addresses", text: $model.logSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer(minLength: 8)
                Button(model.logIsPaused ? "Resume" : "Pause") { model.toggleLogPause() }
                    .help(model.logIsPaused ? "Show new connections again" : "Stop the list moving while you read it")
                Button("Clear") { model.clearLog() }
                Button("Export…") { export() }
                    .help("Save what's shown as a text file")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            AdsLogHeader()
            Divider()
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Text(model.logIsPaused ? "Paused" : "Nothing yet")
                        .font(.system(size: 14, weight: .medium))
                    Text("Each connection your apps open shows here as it's decided, while NetworkMonitor runs.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            AdsLogRow(entry: entry, reason: model.reason(for: entry),
                                      icon: model.icon(forBundle: entry.bundlePath))
                                .contextMenu { menu(for: entry) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func menu(for entry: AdsLogEntry) -> some View {
        if let name = entry.name {
            ForEach(FirewallRules.siteScopes(for: name), id: \.self) { domain in
                let label = domain == name ? domain : "*.\(domain)"
                Section(label) {
                    Button("Allow \(label)") { model.setSite(.allow, domain: domain, name: name, in: nil) }
                    Button("Block \(label)") { model.setSite(.block, domain: domain, name: name, in: nil) }
                    if entry.appKey != nil {
                        Button("Allow \(label) in \(entry.appName)") {
                            model.setSite(.allow, domain: domain, name: name, in: entry)
                        }
                        Button("Block \(label) in \(entry.appName)") {
                            model.setSite(.block, domain: domain, name: name, in: entry)
                        }
                    }
                    let keys: [String?] = entry.appKey.map { [nil, $0] } ?? [nil]
                    ForEach(keys.indices, id: \.self) { index in
                        if let rule = model.rule(forDomain: domain, appKey: keys[index]) {
                            Button("Remove Your Rule: \(rule.title)"
                                   + (rule.appTitle.map { " in \($0)" } ?? "")) { model.remove(rule) }
                        }
                    }
                }
            }
            Divider()
            Button("Copy Name") { copy(name) }
        }
        Button("Copy Address") { copy(entry.address) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NetworkMonitor log.txt"
        panel.allowedContentTypes = [.plainText]
        let text = model.logText()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

private struct AdsLogHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Time").frame(width: AdsMetrics.logTime, alignment: .leading)
            Text("App").frame(width: AdsMetrics.logApp, alignment: .leading)
            Text("Site").frame(maxWidth: .infinity, alignment: .leading)
            Text("Decision").frame(width: AdsMetrics.logDecision, alignment: .leading)
            Text("Why").frame(width: AdsMetrics.logWhy, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}

private struct AdsLogRow: View {
    let entry: AdsLogEntry
    let reason: String
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Text(entry.time.formatted(date: .omitted, time: .standard))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: AdsMetrics.logTime, alignment: .leading)
            HStack(spacing: 6) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(entry.appName).lineLimit(1).truncationMode(.tail)
            }
            .frame(width: AdsMetrics.logApp, alignment: .leading)
            HStack(spacing: 6) {
                if let name = entry.name {
                    Text(name).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(entry.address).lineLimit(1).foregroundStyle(.secondary)
                    Text("NO NAME")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                        .help("Its site couldn't be read, so no list can match it. The app connected by address, "
                              + "and the start of the connection didn't name the site, or named only the "
                              + "service in front of it.")
                }
                ForEach(entry.lists, id: \.self) { list in
                    if let topic = BlocklistTopic(rawValue: list) { ListTag(topic: topic) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isBlocked ? "Blocked" : "Let through")
                .foregroundStyle(entry.isBlocked ? Color.red : Color.secondary)
                .frame(width: AdsMetrics.logDecision, alignment: .leading)
            Text(reason).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                .frame(width: AdsMetrics.logWhy, alignment: .leading)
                .help(reason)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help(entry.name.map { "\($0) · \(entry.address):\(entry.port)" } ?? "\(entry.address):\(entry.port)")
    }
}

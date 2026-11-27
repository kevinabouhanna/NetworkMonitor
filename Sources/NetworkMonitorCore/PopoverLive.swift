import AppKit
import SwiftUI

/// The live speeds' colours in the popover (#802): the ones chosen in
/// Settings › Speed colors, made for a dark menu bar, darkened in their own
/// hue on a light popover as on a light menu bar (#672), so they read on both.
enum LiveTints {
    static func down(_ colors: MenuBarColors) -> Color { tint(colors.live.down) }
    static func up(_ colors: MenuBarColors) -> Color { tint(colors.live.up) }
    static func down(_ tints: MenuBarTints) -> Color { tint(tints.down) }

    private static func tint(_ color: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? color : MenuBarColors.readable(color, onDark: false)
        })
    }
}

extension PopoverMetrics {
    /// The Live line above the buttons: its two lines of text, and the padding
    /// a button has.
    public static let liveLineHeight: CGFloat = 40
    /// The Live view's graph, and the space under it.
    public static let liveGraphHeight: CGFloat = 84
    /// The line naming the apps list's columns.
    public static let liveColumnsHeight: CGFloat = 20
    /// One app in the Live view's list.
    public static let liveRowHeight: CGFloat = 24
    /// The width of a rate's column.
    static let liveRateWidth: CGFloat = 66
    /// The Live line's graph of the last minute, beside ⊞ and ⚙ (#812).
    static let liveSparkWidth: CGFloat = 60
    /// Today / Week / Month, at the top of Data, Connections and Ads blocked
    /// (#812): its small switch (22) with 8 above.
    public static let periodRowHeight: CGFloat = 30
}

/// Today / Week / Month (#812), at the top of the views it changes: Data,
/// Connections and Ads blocked, as Live has 1 · 5 · 15 min at the top of its
/// own. It also sets what their buttons count.
struct PopoverPeriodRow: View {
    @Binding var period: PopoverPeriod

    var body: some View {
        HStack(spacing: 8) {
            PopoverSwitch(name: L("Period"), options: PopoverPeriod.allCases, selection: $period,
                          label: { $0.label }, size: .small)
                .help(L("What Data, Connections and Ads blocked count: today, this week or this month so far, on every network"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PopoverMetrics.edge)
        .padding(.top, 8)
        .frame(height: PopoverMetrics.periodRowHeight, alignment: .bottom)
    }
}

/// The line above the popover's buttons (#802): the speeds now and a small
/// graph of the last minute. A click shows the Live view, and it's raised
/// while that's shown, as a button is.
struct PopoverLiveLine: View {
    @ObservedObject var live: LiveSpeed
    @ObservedObject var colors: MenuBarColors
    let unit: SpeedUnit
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let down = LiveTints.down(colors), up = LiveTints.up(colors)
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 10) {
                        Text("↓ " + rate(live.latest?.down)).foregroundStyle(down)
                        Text("↑ " + rate(live.latest?.up)).foregroundStyle(up)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    Text(L("Live"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                // A preview of the last minute while another view is open:
                // with Live open, its own graph is right below (#812).
                if !isSelected {
                    LiveGraph(samples: live.samples(in: .oneMinute, now: now), span: .oneMinute, now: now,
                              top: top, down: down, up: up, lineWidth: 1.2)
                        .frame(width: PopoverMetrics.liveSparkWidth, height: 24)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .frame(height: PopoverMetrics.liveLineHeight - 2)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(down.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(down.opacity(0.35), lineWidth: 1)
                        }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(L("The speeds right now, and which apps are using the network"))
        .accessibilityLabel(LiveSpeed.spoken(live.latest, unit: unit))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var now: TimeInterval { live.latest?.time ?? 0 }

    private var top: Double {
        let peak = live.samples(in: .oneMinute, now: now).map { max($0.down, $0.up) }.max() ?? 0
        return LiveSpeed.scale(peak: peak, unit: unit).top
    }

    private func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "–" }
        return ByteFormat.speed(bytesPerSecond * 8, unit: unit)
    }
}

/// Download and upload on one scale (#802): download an area, upload a line
/// over it, the newest sample at the right edge.
struct LiveGraph: View {
    let samples: [LiveSample]
    let span: LiveSpan
    let now: TimeInterval
    let top: Double
    let down: Color
    let up: Color
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LiveSeries(samples: samples, upload: false, span: span, now: now, top: top, filled: true)
                    .fill(down.opacity(0.22))
                LiveSeries(samples: samples, upload: false, span: span, now: now, top: top, filled: false)
                    .stroke(down, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
                LiveSeries(samples: samples, upload: true, span: span, now: now, top: top, filled: false)
                    .stroke(up, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// One of the graph's series as a path: a line, or the area under it.
struct LiveSeries: Shape {
    let samples: [LiveSample]
    /// Upload's series, or download's.
    let upload: Bool
    let span: LiveSpan
    let now: TimeInterval
    let top: Double
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1, top > 0 else { return path }
        let start = now - span.seconds
        let points = samples.map { sample -> CGPoint in
            let x = rect.minX + CGFloat((sample.time - start) / span.seconds) * rect.width
            let y = rect.maxY - CGFloat(min((upload ? sample.up : sample.down) / top, 1)) * rect.height
            return CGPoint(x: max(rect.minX, min(x, rect.maxX)), y: y)
        }
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        if filled, let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The Live view (#802): how far back the graph goes, the graph, the apps
/// moving data now, fastest first, and the speed test. As tall as every other
/// view (#599); the apps list shows what fits, and says how many more.
struct PopoverLiveView: View {
    @ObservedObject var live: LiveSpeed
    @ObservedObject var colors: MenuBarColors
    @ObservedObject var speedTest: SpeedTestController
    /// The list's height in the other views: what Live's graph and apps share.
    let listHeight: CGFloat
    let icon: (String, String, String?) -> NSImage
    /// The window's Live page (#812), where ⊞ goes too.
    let onOpen: () -> Void

    var body: some View {
        let down = LiveTints.down(colors), up = LiveTints.up(colors)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PopoverSwitch(name: L("Graph"), options: LiveSpan.allCases, selection: $live.span,
                              label: { $0.label }, size: .small)
                Spacer(minLength: 4)
                Text(count)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, PopoverMetrics.edge)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(height: PopoverMetrics.groupingRowHeight)
            VStack(alignment: .leading, spacing: 0) {
                graph(down: down, up: up)
                columns
                apps(down: down, up: up)
            }
            .frame(height: listHeight, alignment: .top)
            Divider()
            Group {
                if SpeedTestRunner.isAvailable {
                    PopoverSpeedTestRow(speedTest: speedTest)
                        .padding(.horizontal, 12)
                        .frame(height: PopoverMetrics.openRowHeight)
                } else {
                    PopoverOpenRow(title: L("Open Live"), shortcut: "⌘L", action: onOpen)
                }
            }
        }
    }

    private var now: TimeInterval { live.latest?.time ?? 0 }

    private func graph(down: Color, up: Color) -> some View {
        let samples = live.samples(in: live.span, now: now)
        let peak = samples.map { max($0.down, $0.up) }.max() ?? 0
        let scale = LiveSpeed.scale(peak: peak, unit: speedTest.unit)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                Divider().opacity(0.6)
                Spacer()
                Divider().opacity(0.6)
            }
            LiveGraph(samples: samples, span: live.span, now: now, top: scale.top, down: down, up: up)
                .padding(.top, 1)
            Text(scale.label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.top, 3)
                .padding(.leading, 2)
        }
        .frame(height: PopoverMetrics.liveGraphHeight - 8)
        .padding(.horizontal, PopoverMetrics.edge)
        .padding(.top, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Graph of download and upload speeds, %@, up to %@", live.span.phrase, scale.label))
    }

    private var columns: some View {
        HStack(spacing: 0) {
            Text(L("Using the network now"))
            Spacer(minLength: 4)
            Text("↓").frame(width: PopoverMetrics.liveRateWidth, alignment: .trailing)
            Text("↑").frame(width: PopoverMetrics.liveRateWidth, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, PopoverMetrics.edge)
        .frame(height: PopoverMetrics.liveColumnsHeight)
        .accessibilityHidden(true)
    }

    /// How many rows fit under the graph and the columns' names.
    private var fitting: Int {
        let room = listHeight - PopoverMetrics.liveGraphHeight - PopoverMetrics.liveColumnsHeight
        return max(Int(room / PopoverMetrics.liveRowHeight), 0)
    }

    @ViewBuilder
    private func apps(down: Color, up: Color) -> some View {
        if live.apps.isEmpty {
            Text(L("No app is using the network right now"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(live.apps.prefix(fitting)) { app in
                    HStack(spacing: 7) {
                        Image(nsImage: icon(app.id, app.name, app.bundlePath))
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(app.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(ByteFormat.speed(app.down * 8, unit: speedTest.unit))
                            .foregroundStyle(down)
                            .frame(width: PopoverMetrics.liveRateWidth, alignment: .trailing)
                        Text(ByteFormat.speed(app.up * 8, unit: speedTest.unit))
                            .foregroundStyle(up)
                            .frame(width: PopoverMetrics.liveRateWidth, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, PopoverMetrics.edge)
                    .frame(height: PopoverMetrics.liveRowHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("%@, download %@, upload %@", app.name,
                                          ByteFormat.spokenSpeed(app.down * 8, unit: speedTest.unit),
                                          ByteFormat.spokenSpeed(app.up * 8, unit: speedTest.unit)))
                }
            }
        }
    }

    /// "5 apps now", or the ones not shown too: "9 apps now, 4 not shown".
    private var count: String {
        let all = live.apps.count
        let words = all == 1 ? L("1 app now") : L("%@ apps now", String(all))
        let hidden = all - min(all, fitting)
        return hidden > 0 ? L("%@, %@ not shown", words, String(hidden)) : words
    }
}

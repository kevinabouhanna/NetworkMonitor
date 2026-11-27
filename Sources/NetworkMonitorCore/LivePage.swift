import AppKit
import SwiftUI

/// The main window's Live page (#812), first in its sidebar: the popover's
/// Live with room. The speeds now, a wide graph over 1, 5 or 15 minutes (the
/// popover's span, one choice for both), every app moving data now and the
/// ones that were a moment ago, and the speed test, which moved here from
/// Network as it did in the popover. Its colours are the ones chosen in
/// Settings › Speed colors.
///
/// Across the window's whole width (#825). With room, in two columns under
/// the graph: the apps list fills the left and the window's height,
/// scrolling inside itself, and the speed test has a column of its own on
/// the right. Narrower, the test goes under the list, which keeps a fixed
/// height of eight rows. Either way the test stays where it is however many
/// apps come and go.
struct LivePageView: View {
    @ObservedObject var live: LiveSpeed
    @ObservedObject var colors: MenuBarColors
    @ObservedObject var speedTest: SpeedTestController
    let icon: (String, String, String?) -> NSImage

    var body: some View {
        GeometryReader { proxy in
            if LivePageMetrics.hasColumns(width: proxy.size.width) {
                columns
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        top
                        VStack(alignment: .leading, spacing: 0) {
                            appsHeader
                            ScrollView(.vertical) { appRows }
                                .frame(height: LivePageMetrics.listHeight, alignment: .top)
                        }
                        if SpeedTestRunner.isAvailable { test(stacked: false) }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The list on the left, filling the height, and the test beside it.
    private var columns: some View {
        VStack(alignment: .leading, spacing: 18) {
            top
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    appsHeader
                    ScrollView(.vertical) { appRows }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if SpeedTestRunner.isAvailable {
                    // Its own scroll, for a short window while a test runs.
                    ScrollView(.vertical) { test(stacked: true) }
                        .frame(width: LivePageMetrics.testColumnWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The figures, the span's switch and the graph, across the whole width.
    @ViewBuilder
    private var top: some View {
        let down = LiveTints.down(colors), up = LiveTints.up(colors)
        let now = live.latest?.time ?? 0
        let samples = live.samples(in: live.span, now: now)
        let peak = samples.map { max($0.down, $0.up) }.max() ?? 0
        let scale = LiveSpeed.scale(peak: peak, unit: speedTest.unit)
        let figures = Group {
            figure("↓ " + rate(live.latest?.down), spoken: spoken(live.latest?.down),
                   caption: L("Download now"), color: down)
            figure("↑ " + rate(live.latest?.up), spoken: spoken(live.latest?.up),
                   caption: L("Upload now"), color: up)
            figure(rate(peak), spoken: spoken(peak), caption: L("Fastest in the graph"), color: .primary,
                   size: 18)
        }
        let span = PopoverSwitch(name: L("Graph"), options: LiveSpan.allCases, selection: $live.span,
                                 label: { $0.label })
        // The switch beside the figures while they fit whole; under them,
        // at the graph's right, on a narrow window (#825).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                figures.fixedSize()
                Spacer(minLength: 8)
                span
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 28) { figures }
                HStack { Spacer(); span }
            }
        }
        graph(samples: samples, now: now, scale: scale, down: down, up: up)
    }

    private func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "–" }
        return ByteFormat.speed(bytesPerSecond * 8, unit: speedTest.unit)
    }

    /// As VoiceOver reads a speed: "12.3 megabits per second".
    private func spoken(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "–" }
        return ByteFormat.spokenSpeed(bytesPerSecond * 8, unit: speedTest.unit)
    }

    private func figure(_ value: String, spoken: String, caption: String, color: Color,
                        size: CGFloat = 26) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                // A fast line's figures in the narrowest window.
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 50, alignment: .bottomLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("%@, %@", caption, spoken))
    }

    private func graph(samples: [LiveSample], now: TimeInterval, scale: (top: Double, label: String),
                       down: Color, up: Color) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Divider()
                    Spacer()
                    Divider().opacity(0.5)
                    Spacer()
                    Divider()
                }
                LiveGraph(samples: samples, span: live.span, now: now, top: scale.top, down: down, up: up,
                          lineWidth: 1.8)
                    .padding(.top, 1)
                Text(scale.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.top, 4)
                    .padding(.leading, 2)
            }
            .frame(height: LivePageMetrics.graphHeight)
            HStack {
                Text(L("%@ ago", live.span.label))
                Spacer()
                Text(L("Now"))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Graph of download and upload speeds, %@, up to %@", live.span.phrase, scale.label))
    }

    /// The list's header, which stays put while its rows scroll.
    private var appsHeader: some View {
        HStack(spacing: 0) {
            Text(L("Using the network now"))
            Text("  " + (live.apps.count == 1 ? L("1 app now") : L("%@ apps now", String(live.apps.count))))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(L("Download")).frame(width: LivePageMetrics.rateWidth, alignment: .trailing)
            Text(L("Upload")).frame(width: LivePageMetrics.rateWidth, alignment: .trailing)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var appRows: some View {
        let down = LiveTints.down(colors), up = LiveTints.up(colors)
        let rows = live.recentApps
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(L("No app is using the network right now"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(rows) { app in
                    Divider()
                    HStack(spacing: 9) {
                        Image(nsImage: icon(app.id, app.name, app.bundlePath))
                            .resizable()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        Text(app.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(ByteFormat.speed(app.down * 8, unit: speedTest.unit))
                            .foregroundStyle(app.total > 0 ? down : Color.secondary)
                            .frame(width: LivePageMetrics.rateWidth, alignment: .trailing)
                        Text(ByteFormat.speed(app.up * 8, unit: speedTest.unit))
                            .foregroundStyle(app.total > 0 ? up : Color.secondary)
                            .frame(width: LivePageMetrics.rateWidth, alignment: .trailing)
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .frame(height: LivePageMetrics.rowHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("%@, download %@, upload %@", app.name,
                                          ByteFormat.spokenSpeed(app.down * 8, unit: speedTest.unit),
                                          ByteFormat.spokenSpeed(app.up * 8, unit: speedTest.unit)))
                }
            }
        }
        // Clear of the scroll bar, when it shows.
        .padding(.trailing, 4)
    }

    /// The speed test, as it was on the Network page; stacked in its column.
    private func test(stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Speed test"))
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            SpeedTestPanel(speedTest: speedTest, stacked: stacked)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            SettingsFootnote(L("Runs macOS's built-in networkQuality, only when you start it: download first, then upload. Every run measures afresh, so it uses data each time — typically 50–500 MB, more on a very fast line. Speeds use the unit chosen in General."))
        }
    }
}

public enum LivePageMetrics {
    static let graphHeight: CGFloat = 200
    static let rowHeight: CGFloat = 30
    static let rateWidth: CGFloat = 110
    /// The narrowest Live's content reads well at: its three figures and
    /// the switch in a row.
    static let minWidth: CGFloat = 600
    /// The speed test's column (#825): the running test's card, 320, and
    /// the panel's padding.
    public static let testColumnWidth: CGFloat = 344
    /// The list's height when the test is under it: eight rows, each with
    /// the line above it.
    static let listHeight: CGFloat = 8 * (rowHeight + 1)
    /// The page's content width from which the test has a column of its
    /// own (#825): the list keeps room for a name and both rates beside it.
    public static let columnsFrom: CGFloat = 900

    /// Whether a page this wide (its padding included) has two columns.
    public static func hasColumns(width: CGFloat) -> Bool { width - 40 >= columnsFrom }
}

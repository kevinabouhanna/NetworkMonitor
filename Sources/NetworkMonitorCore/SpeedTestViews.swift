import SwiftUI

/// Colours and scale shared by every speed test view.
enum SpeedTestPalette {
    /// Cyan for download and purple for upload: the pairing most speed tests use,
    /// and distinct from the app list's accent bars so a test is never read as
    /// one more app.
    static let download = Color.cyan
    static let upload = Color.purple

    /// Position of a rate along a gauge, 0...1, on a log scale.
    ///
    /// Linear would pin every home connection to the left edge of a gigabit
    /// scale; log puts 10, 100 and 1000 Mbps at roughly a third, two thirds and
    /// the end — the same spread speed test dials have always used. Lines faster
    /// than a gigabit move to a 10 Gbps scale rather than sitting at the stop.
    static func fraction(_ bitsPerSecond: Double, scaleMbps: Double) -> Double {
        let mbps = max(bitsPerSecond / 1e6, 0)
        guard mbps.isFinite else { return 0 }
        return min(log10(1 + mbps) / log10(1 + scaleMbps), 1)
    }

    static func scaleMbps(for values: Double...) -> Double {
        (values.max() ?? 0) > 1e9 ? 10_000 : 1_000
    }

    /// A rate split for display, with a dash for a direction that has not
    /// started. "0.00 bps" for an upload still waiting its turn reads as a
    /// measurement of zero rather than as "not yet".
    static func parts(_ bitsPerSecond: Double,
                      _ unit: SpeedUnit) -> (number: String, unit: String) {
        bitsPerSecond > 0 ? ByteFormat.speedParts(bitsPerSecond, unit: unit) : ("—", unit.label)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 100 ? String(format: "%.0f ms", value) : String(format: "%.1f ms", value)
    }

    /// One plain sentence on how the line copes when busy, or nil when it copes.
    ///
    /// 100 ms is where a call starts to feel it: the ITU's one-way budget for
    /// conversation is 150 ms, and an idle ping has already spent part of that.
    static func loadNote(_ result: SpeedTestResult) -> String? {
        guard let rise = result.loadedPingIncrease, rise >= 100 else { return nil }
        return "Ping rises by \(Int(rise.rounded())) ms when the line is busy, "
            + "so calls may lag during big downloads"
    }

    /// What each figure means, for its tooltip.
    static let pingHelp = "Round trip to the test server on a quiet line. "
        + "Under 50 ms is great; over 100 ms is noticeable in calls and games."
    static let jitterHelp = "How much ping varies from one moment to the next. "
        + "Under 10 ms is good; more makes calls choppy."
    static let loadedHelp = "Ping measured while the test fills the line. A big rise over "
        + "the quiet-line ping means calls and games lag whenever something downloads or uploads."

    /// "Google Chrome used 12.4 MB during the test", or two apps, or "and 3 others".
    static func contentionNote(_ result: SpeedTestResult) -> String {
        let top = result.competingTraffic.prefix(2).map(\.displayName)
        let rest = result.competingTraffic.count - top.count
        var names = top.joined(separator: " and ")
        if rest > 0 { names = top.joined(separator: ", ") + " and \(rest) more" }
        return "\(names) used \(ByteFormat.bytes(result.competingBytes)) during the test — "
            + "figures may read low"
    }

    static func meteredNote(_ estimate: Int64?) -> String {
        if let estimate {
            return "Metered connection. The last test here used \(ByteFormat.bytes(estimate))."
        }
        return "Metered connection. A test can use 100 MB or more on a fast line."
    }
}

// MARK: - Header button

/// The popover's way in: one press, one fresh measurement.
///
/// When the card has been put away mid-test, the button carries the live
/// reading and brings the card back, so a test sent out of sight is never lost.
struct SpeedTestButton: View {
    @ObservedObject var speedTest: SpeedTestController

    private var isHiddenRun: Bool {
        speedTest.phase != .idle && !speedTest.isPresented
    }

    var body: some View {
        Button {
            if isHiddenRun { speedTest.present() } else { speedTest.run() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 13))
                if isHiddenRun, speedTest.phase.isRunning {
                    HeaderLiveReading(live: speedTest.live, unit: speedTest.unit)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(speedTest.phase == .idle
                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(SpeedTestPalette.download))
        .disabled(speedTest.phase.isRunning && !isHiddenRun)
        .help(isHiddenRun ? "Show the speed test"
              : speedTest.phase.isRunning ? "Speed test running" : "Test internet speed")
    }
}

/// "↓ 17.2" beside the gauge while a hidden test runs.
private struct HeaderLiveReading: View {
    @ObservedObject var live: SpeedTestController.Live
    let unit: SpeedUnit

    var body: some View {
        let uploading = live.progress.stage == .upload
        let bits = uploading ? live.progress.uploadBitsPerSecond
                             : live.progress.downloadBitsPerSecond
        Text("\(uploading ? "↑" : "↓") \(SpeedTestPalette.parts(bits, unit).number)")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(uploading ? SpeedTestPalette.upload : SpeedTestPalette.download)
    }
}

// MARK: - Card

/// Takes the list's place while a test is on screen, with a dial and the
/// full breakdown. "Back to Apps" returns the list.
///
/// Running and finished share one layout, the tiles filling in as figures
/// arrive, so the result lands in place instead of the card rearranging itself
/// at the moment the user is reading it.
struct SpeedTestCard: View {
    @ObservedObject var speedTest: SpeedTestController

    var body: some View {
        VStack(spacing: 0) {
            switch speedTest.phase {
            case .idle:
                EmptyView()
            case .confirming(let estimate):
                confirming(estimate)
            case .running(let startedAt):
                CardBody(live: speedTest.live, result: nil, startedAt: startedAt,
                         unit: speedTest.unit)
                Spacer(minLength: 0)
                buttons(primary: "Stop", primaryAction: { speedTest.dismiss() })
            case .finished(let result):
                CardBody(live: speedTest.live, result: result, startedAt: nil,
                         unit: speedTest.unit)
                Spacer(minLength: 0)
                buttons(primary: "Test Again", primaryAction: { speedTest.run() })
            case .failed(let message):
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundStyle(.orange)
                Text("Speed test didn't finish")
                    .font(.system(size: 13, weight: .semibold)).padding(.top, 8)
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 2)
                Spacer()
                buttons(primary: "Try Again", primaryAction: { speedTest.run() })
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 12)
        .padding(.horizontal, 14)
        .frame(height: PopoverMetrics.speedCardHeight)
    }

    private func confirming(_ estimate: Int64?) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 26)).foregroundStyle(.orange)
            Text("Test on a metered connection?")
                .font(.system(size: 13, weight: .semibold))
            Text(SpeedTestPalette.meteredNote(estimate))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            Spacer()
            buttons(primary: "Run Anyway", primaryAction: { speedTest.confirm() })
        }
    }

    private func buttons(primary: String, primaryAction: @escaping () -> Void) -> some View {
        HStack {
            // Leaves the card, never the test: a run in progress carries on and
            // the header button brings it back. Stop is the button that stops.
            Button("Back to Apps") { speedTest.hide() }
                .controlSize(.small)
            Spacer()
            Button(primary, action: primaryAction)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Dial, caption, tiles and note — fed by the live readings while running and
/// by the result once there is one. The only view that watches `live`.
private struct CardBody: View {
    @ObservedObject var live: SpeedTestController.Live
    let result: SpeedTestResult?
    let startedAt: Date?
    let unit: SpeedUnit

    var body: some View {
        let progress = live.progress
        let down = result?.downloadBitsPerSecond ?? progress.downloadBitsPerSecond
        let up = result?.uploadBitsPerSecond ?? progress.uploadBitsPerSecond
        // The dial's figure follows the half being measured, as every speed test
        // does, and settles on the download once both are in.
        let showsUpload = result == nil && progress.stage == .upload

        VStack(spacing: 0) {
            SpeedDial(download: down, upload: up, unit: unit, showsUpload: showsUpload)
            HStack(spacing: 16) {
                legend("Download", down, SpeedTestPalette.download)
                legend("Upload", up, SpeedTestPalette.upload)
            }
            .padding(.top, 6)
            caption(progress)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            // Every figure here is reported when the run ends, so the tiles
            // wait as dashes and fill in place.
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    tile("Ping", SpeedTestPalette.milliseconds(result?.ping),
                         help: SpeedTestPalette.pingHelp)
                    tile("Jitter", SpeedTestPalette.milliseconds(result?.jitter),
                         help: SpeedTestPalette.jitterHelp)
                }
                HStack(spacing: 8) {
                    tile("Ping while downloading",
                         SpeedTestPalette.milliseconds(result?.downloadPing),
                         help: SpeedTestPalette.loadedHelp)
                    tile("Ping while uploading",
                         SpeedTestPalette.milliseconds(result?.uploadPing),
                         help: SpeedTestPalette.loadedHelp)
                }
            }
            .padding(.top, 10)

            note.padding(.top, 9)
        }
    }

    private func caption(_ progress: SpeedTestProgress) -> AnyView {
        if let result {
            var parts: [String] = []
            if let kind = result.interfaceKind { parts.append(kind) }
            parts.append("used " + ByteFormat.bytes(result.bytesTransferred))
            parts.append(result.finishedAt.formatted(date: .omitted, time: .shortened))
            return AnyView(Text(parts.joined(separator: " · ")))
        }
        guard let startedAt else { return AnyView(EmptyView()) }
        let stage: String
        switch progress.stage {
        case .starting: stage = "Measuring ping"
        case .download: stage = "Testing download"
        case .upload:   stage = "Testing upload"
        case .finishing: stage = "Measuring ping"
        }
        return AnyView(Text("\(stage) · ") + Text(startedAt, style: .timer)
                       + Text(" · \(ByteFormat.bytes(progress.bytesTransferred))"))
    }

    @ViewBuilder
    private var note: some View {
        if let result, result.wasContended {
            Label(SpeedTestPalette.contentionNote(result),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let result, let load = SpeedTestPalette.loadNote(result) {
            Text(load)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else if result == nil {
            Text("Download first, then upload, like any speed test")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func legend(_ title: String, _ bits: Double, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(bits > 0 ? ByteFormat.speed(bits, unit: unit) : "—")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func tile(_ title: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(result == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .help(help)
    }
}

/// A half-circle gauge: download on the outer arc, upload on the inner, the
/// scale printed just outside so nothing crowds the figure in the middle.
struct SpeedDial: View {
    let download: Double
    let upload: Double
    let unit: SpeedUnit
    /// Puts the upload figure in the middle, while the upload is being measured.
    var showsUpload = false

    /// Diameter of the outer arc's centre line plus its stroke.
    static let arcWidth: CGFloat = 188
    /// Room left around the arcs for the scale labels.
    static let labelMargin: CGFloat = 16
    static let outerLine: CGFloat = 11
    static let innerLine: CGFloat = 5
    /// How far the inner arc's centre line sits inside the outer arc's edge.
    static let innerInset: CGFloat = 19

    static var width: CGFloat { arcWidth + labelMargin * 2 }
    /// One of the app's megabytes per second, in megabits: 1024 × 1024 × 8 bits.
    static let megabyte = 8.388608
    static var height: CGFloat { labelMargin + arcWidth / 2 + outerLine / 2 }

    var body: some View {
        let scale = SpeedTestPalette.scaleMbps(for: download, upload)
        let downFraction = SpeedTestPalette.fraction(download, scaleMbps: scale)
        let upFraction = SpeedTestPalette.fraction(upload, scaleMbps: scale)
        let parts = SpeedTestPalette.parts(showsUpload ? upload : download, unit)
        let outer = Self.labelMargin + Self.outerLine / 2
        let inner = Self.labelMargin + Self.innerInset

        ZStack(alignment: .bottom) {
            DialArc(fraction: 1, inset: outer)
                .stroke(.secondary.opacity(0.15),
                        style: StrokeStyle(lineWidth: Self.outerLine, lineCap: .round))
            // Animated per arc, never on the stack: an animation on the stack
            // cross-fades the figure below between readings, ghosting the digits.
            DialArc(fraction: downFraction, inset: outer)
                .stroke(SpeedTestPalette.download,
                        style: StrokeStyle(lineWidth: Self.outerLine, lineCap: .round))
                .opacity(downFraction > 0 ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: downFraction)
            DialArc(fraction: 1, inset: inner)
                .stroke(.secondary.opacity(0.12),
                        style: StrokeStyle(lineWidth: Self.innerLine, lineCap: .round))
            DialArc(fraction: upFraction, inset: inner)
                .stroke(SpeedTestPalette.upload,
                        style: StrokeStyle(lineWidth: Self.innerLine, lineCap: .round))
                .opacity(upFraction > 0 ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: upFraction)
            ticks(scale)
            VStack(spacing: 0) {
                Text(parts.number)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("\(parts.unit) \(showsUpload ? "up" : "down")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.width, height: Self.height)
    }

    /// Scale labels just outside the outer arc, at their log positions, in the
    /// chosen unit. The needle's scale stays in bits either way; only where the
    /// round numbers fall on it changes.
    private func ticks(_ scale: Double) -> some View {
        let marks: [(Double, String)]
        switch (unit, scale > 1_000) {
        case (.bits, false):
            marks = [(0, "0"), (1, "1"), (10, "10"), (100, "100"), (1_000, "1000")]
        case (.bits, true):
            marks = [(0, "0"), (10, "10"), (100, "100"), (1_000, "1000"), (10_000, "10k")]
        case (.bytes, false):
            marks = [(0, "0"), (1, "1"), (10, "10"), (100, "100")].map { ($0.0 * Self.megabyte, $0.1) }
        case (.bytes, true):
            marks = [(0, "0"), (10, "10"), (100, "100"), (1_000, "1000")].map { ($0.0 * Self.megabyte, $0.1) }
        }
        return GeometryReader { geometry in
            let radius = Self.arcWidth / 2 + 8
            let center = CGPoint(x: geometry.size.width / 2,
                                 y: geometry.size.height - Self.outerLine / 2)
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                let fraction = SpeedTestPalette.fraction(mark.0 * 1e6, scaleMbps: scale)
                let angle = Double.pi + Double.pi * fraction
                Text(mark.1)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .position(x: center.x + radius * cos(angle),
                              y: center.y + radius * sin(angle))
            }
        }
    }
}

/// The top half of a circle, swept left to right up to `fraction`.
///
/// Drawn from sampled points rather than `addArc`, whose clockwise flag reads
/// inverted in SwiftUI's flipped coordinates — this way the direction is simply
/// the one the angles describe. Animatable, so the needle glides between readings.
struct DialArc: Shape {
    var fraction: Double
    var inset: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height) - inset
        let center = CGPoint(x: rect.midX, y: rect.maxY - SpeedDial.outerLine / 2)
        let clamped = min(max(fraction, 0), 1)
        let steps = max(Int(90 * clamped), 1)
        var path = Path()
        for step in 0...steps {
            let angle = Double.pi + Double.pi * clamped * Double(step) / Double(steps)
            let point = CGPoint(x: center.x + radius * cos(angle),
                                y: center.y + radius * sin(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

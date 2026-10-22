import Combine
import Foundation

/// The speed test as the UI sees it: what phase it is in, and what to draw.
///
/// Split across two observable objects on purpose, for the reason
/// `MonitorViewModel.downBytesPerSecond` gives at length: an observer is
/// invalidated by *any* change to the object it watches. The popover only needs
/// to know when the phase changes — a handful of times per test — so it watches
/// this object. The dial needs every reading, five a second, so it alone watches
/// `live`. Folding the two together would rebuild the whole app list five times a
/// second for numbers it never shows.
public final class SpeedTestController: ObservableObject {

    public enum Phase: Equatable {
        case idle
        /// Waiting for the user to accept the data cost of testing on a metered
        /// connection. Carries what the last test here cost, when known.
        case confirming(estimatedBytes: Int64?)
        case running(startedAt: Date)
        case finished(SpeedTestResult)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// The live reading, published separately. See the type's documentation.
    public final class Live: ObservableObject {
        @Published public fileprivate(set) var progress = SpeedTestProgress()
    }

    @Published public private(set) var phase: Phase = .idle
    public let live = Live()

    /// Whether the card is on screen. Separate from `phase` because leaving the
    /// card is not the same as stopping the test: "Back to Apps" mid-run hides
    /// the card and lets the measurement finish, and the header button brings
    /// it back.
    @Published public private(set) var isPresented = false

    /// Bits or bytes for every speed the app shows: the test's figures and the
    /// menu bar's live rates. Held here because the test is where the choice was
    /// first offered and its views already observe this object; the menu bar
    /// reads it through `MonitorViewModel`. See `SpeedUnit`.
    @Published public var unit: SpeedUnit {
        didSet {
            defaults.set(unit.rawValue, forKey: Keys.unit)
            menuBarDidChange?()
        }
    }
    /// Whether the menu bar title shows the test while it runs.
    @Published public var showsInMenuBar: Bool {
        didSet {
            defaults.set(showsInMenuBar, forKey: Keys.menuBar)
            menuBarDidChange?()
        }
    }

    /// The most recent result on the current connection, for the right-click
    /// menu's summary line. Memory only, and dropped on a network change: it
    /// describes a connection, and a figure for the previous one would be wrong
    /// rather than old.
    @Published public private(set) var lastResult: SpeedTestResult?

    /// Asked before each run. Wired to the metering verdict by the view model.
    public var isMetered: () -> Bool = { false }
    /// Called whenever what the menu bar should show changes.
    public var menuBarDidChange: (() -> Void)?

    /// How long a finished result stays in the menu bar before the live rates
    /// return. Long enough to read after glancing up, short enough not to be
    /// mistaken for the current rate.
    public static let menuBarHold: TimeInterval = 8

    private let runner: SpeedTestRunner
    private let defaults: UserDefaults
    private var menuBarHoldUntil: Date?
    private var holdWork: DispatchWorkItem?
    /// Other apps' internet bytes seen while the current run is in progress.
    private var competing: [String: Int64] = [:]

    private enum Keys {
        /// Named for the speed test, which it governed alone until 1.5. Kept,
        /// so a unit someone chose then stays theirs now that it covers the
        /// menu bar too.
        static let unit = "speedTestUnit"
        static let menuBar = "speedTestInMenuBar"
    }

    public init(runner: SpeedTestRunner = SpeedTestRunner(),
                defaults: UserDefaults = .standard) {
        self.runner = runner
        self.defaults = defaults
        // Bytes unless chosen otherwise, so upgrading never changes the menu bar.
        // The key is written only when someone picks a unit, so anyone who chose
        // one for the speed test keeps it.
        self.unit = SpeedUnit(rawValue: defaults.string(forKey: Keys.unit) ?? "") ?? .bytes
        self.showsInMenuBar = defaults.object(forKey: Keys.menuBar) as? Bool ?? true
    }

    // MARK: Actions

    /// Starts a fresh test, unless the connection is metered and the user has
    /// not yet agreed to spend the data.
    ///
    /// Always a new measurement. Pressing the button again after a result is on
    /// screen measures again; nothing on this path returns an earlier figure.
    public func run() {
        guard !phase.isRunning else { return }
        isPresented = true
        if isMetered() {
            phase = .confirming(estimatedBytes: lastResult?.bytesTransferred)
            return
        }
        begin()
    }

    /// Runs on a metered connection, after the user has seen the cost.
    public func confirm() {
        guard case .confirming = phase else { return }
        begin()
    }

    /// Brings the card back for a test that is running or has just finished.
    public func present() {
        guard phase != .idle else { return }
        isPresented = true
    }

    /// "Back to Apps". A running test carries on out of sight; anything else —
    /// a result, an error, an unanswered metered prompt — is put away, so the
    /// next press of the header button measures afresh.
    public func hide() {
        if phase.isRunning {
            isPresented = false
        } else {
            dismiss()
        }
    }

    /// Stops a running test, or leaves the result or error on screen.
    public func dismiss() {
        if phase.isRunning { runner.cancel() }
        isPresented = false
        phase = .idle
        live.progress = SpeedTestProgress()
        endMenuBarHold()
        menuBarDidChange?()
    }

    /// Ends any run and forgets the last result. The connection it described is
    /// gone, and a test spanning two networks measures neither.
    public func networkDidChange() {
        let wasRunning = phase.isRunning
        if wasRunning { runner.cancel() }
        lastResult = nil
        endMenuBarHold()
        switch phase {
        case .running:
            phase = .failed("The network changed during the test")
        case .finished, .confirming:
            phase = .idle
        case .idle, .failed:
            break
        }
        live.progress = SpeedTestProgress()
        menuBarDidChange?()
    }

    public func stop() {
        runner.cancel()
    }

    /// Credits other apps' traffic to the running test, so a result dragged down
    /// by a background download can say so. Called from the view model with each
    /// nettop sample; ignored when no test is running.
    ///
    /// The test's own process is excluded by name: `networkQuality` here is
    /// adopted under NetworkMonitor, and one started from Terminal is a speed test
    /// too, not competing traffic.
    public func recordBackground(_ entries: [(displayName: String, key: String, bytes: Int64)]) {
        guard phase.isRunning else { return }
        for entry in entries where entry.bytes > 0 {
            guard !entry.key.localizedCaseInsensitiveContains("networkQuality") else { continue }
            competing[entry.displayName, default: 0] += entry.bytes
        }
    }

    // MARK: Menu bar

    /// What the menu bar should draw instead of the live rates, if anything.
    public var menuBarReading: (down: Double, up: Double)? {
        guard showsInMenuBar else { return nil }
        switch phase {
        case .running:
            return (live.progress.downloadBitsPerSecond, live.progress.uploadBitsPerSecond)
        case .finished(let result):
            guard let until = menuBarHoldUntil, until > Date() else { return nil }
            return (result.downloadBitsPerSecond, result.uploadBitsPerSecond)
        default:
            return nil
        }
    }

    public var isShowingInMenuBar: Bool { menuBarReading != nil }

    // MARK: Running

    private func begin() {
        competing.removeAll()
        live.progress = SpeedTestProgress()
        endMenuBarHold()
        phase = .running(startedAt: Date())
        menuBarDidChange?()

        runner.start { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
    }

    private func handle(_ event: SpeedTestRunner.Event) {
        guard phase.isRunning else { return }
        switch event {
        case .progress(let progress):
            live.progress = progress
            if showsInMenuBar { menuBarDidChange?() }

        case .finished(.success(var result)):
            result.competingTraffic = competing
                .map { CompetingTraffic(displayName: $0.key, bytes: $0.value) }
                .sorted { $0.bytes > $1.bytes }
            competing.removeAll()
            lastResult = result
            phase = .finished(result)
            startMenuBarHold()

        case .finished(.failure(let failure)):
            competing.removeAll()
            switch failure {
            case .unreadable:
                phase = .failed("networkQuality returned a result this app could not read")
            case .toolError(let message):
                phase = .failed(message)
            }
            menuBarDidChange?()
        }
    }

    private func startMenuBarHold() {
        holdWork?.cancel()
        menuBarHoldUntil = Date().addingTimeInterval(Self.menuBarHold)
        menuBarDidChange?()
        let work = DispatchWorkItem { [weak self] in
            self?.menuBarHoldUntil = nil
            self?.menuBarDidChange?()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuBarHold, execute: work)
    }

    private func endMenuBarHold() {
        holdWork?.cancel()
        holdWork = nil
        menuBarHoldUntil = nil
    }
}

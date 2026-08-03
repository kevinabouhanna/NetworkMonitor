import AppKit
import NetworkMonitorCore

// Built as a plain executable rather than via @NSApplicationMain so the whole
// app can live in a SwiftPM package with no Xcode project. `LSUIElement` in
// Info.plist is what keeps it out of the Dock and the app switcher; setting
// .accessory here as well means a bare binary run from the terminal behaves the
// same way as the bundled .app.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// Uninstall hook, handled before everything else: deleting the app bundle
// leaves the login item registered, and only the app itself can withdraw that
// registration. Runs without starting the UI, and before the single-instance
// guard so it works while a copy is already running.
if CommandLine.arguments.contains("--unregister-login-item") {
    LoginItem.withdraw()
    exit(0)
}

// The other uninstall hook, and the more important one. Every metering change is
// made to something this app does not own — another app's update preference, a
// LaunchAgent — and the only record of how to put them back is
// `suppression.json`, which is about to be deleted along with the bundle.
// Restoring has to happen while both still exist, so `uninstall.sh` calls this
// first and waits for it.
//
// Deliberately independent of the running instance: it reads the journal from
// disk and reverts from there, so it works whether or not the app is running and
// whether or not the setting was ever switched on.
if CommandLine.arguments.contains("--revert-metering") {
    MeteringController(store: UsageStore()).revertAll()
    exit(0)
}

// Single-instance guard. Two copies would each add a status item and each run
// their own nettop, double-counting every byte. This also makes the duplicate
// launch that `launchctl bootstrap` triggers (via RunAtLoad) harmless: it exits
// immediately and leaves the original running.
if let identifier = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        // Surface the existing instance's menu bar item rather than dying silently.
        others.first?.activate()
        exit(0)
    }
}

var signalSources: [DispatchSourceSignal] = []
let delegate = AppDelegate()
application.delegate = delegate

// Terminating signals bypass `applicationWillTerminate`, which would leave the
// `nettop` child alive after the app is gone (verified: `pkill` on the app left
// an orphan holding ~1.4 cores). Trapping them routes through a normal AppKit
// quit so the subprocess is always torn down.
for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSources.append(source)
    // The dispatch source only fires if the default disposition is ignored.
    signal(signalNumber, SIG_IGN)
}

application.run()

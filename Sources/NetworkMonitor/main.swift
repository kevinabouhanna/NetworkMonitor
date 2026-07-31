import AppKit

// Built as a plain executable rather than via @NSApplicationMain so the whole
// app can live in a SwiftPM package with no Xcode project. `LSUIElement` in
// Info.plist is what keeps it out of the Dock and the app switcher; setting
// .accessory here as well means a bare binary run from the terminal behaves the
// same way as the bundled .app.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

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

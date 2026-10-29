import Foundation
import NetworkExtension

// NetworkMonitor's content filter (#128): a system extension that sees each
// new connection as it opens. In this version it allows every one and tells
// the app where it went; blocking comes with #114.
//
// macOS starts it as a system extension, never by hand. It listens for the
// app on its Mach service, then hands control to NetworkExtension.

AppLink.shared.start()

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()

import AppKit
import SwiftUI

/// The Connections window: its own, not a Settings pane, because it's read
/// beside other work and wants room. It's resizable, which Settings' fixed
/// width can't be, and will want more room again once the map sits beside the
/// list (#113).
public final class ConnectionsWindowController: NSObject {

    public let window: NSWindow
    private let model: ConnectionsViewModel

    public init(model: ConnectionsViewModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        let host = NSHostingController(rootView: ConnectionsView(model: model))
        // The window keeps the size it's given or dragged to. Sized to its
        // content, it would jump each time the list grew or shrank.
        host.sizingOptions = []
        window.contentViewController = host
        window.title = "Connections"
        window.setContentSize(NSSize(width: 780, height: 700))
        window.contentMinSize = NSSize(width: ConnectionsMetrics.minWidth, height: ConnectionsMetrics.minHeight)
        window.isReleasedWhenClosed = false
    }

    public var isVisible: Bool { window.isVisible }

    public func windowDidShow() { model.windowDidOpen() }

    public func windowWillClose() { model.windowDidClose() }
}

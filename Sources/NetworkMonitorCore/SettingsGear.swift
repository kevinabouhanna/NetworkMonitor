import AppKit

/// The gear at the end of a window's toolbar (#436): it opens that feature's
/// pane of Settings, so a gear always means settings, wherever it is.
/// Connections, Ads and Trackers and Usage History each have one.
enum SettingsGear {
    static let identifier = NSToolbarItem.Identifier("settings")

    /// A plain bordered toolbar button with the gear, named "Settings" for
    /// VoiceOver and the toolbar's text mode.
    static func item(target: AnyObject, action: Selector, help: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("Settings"))
        item.label = L("Settings")
        item.paletteLabel = L("Settings")
        item.toolTip = help
        item.isBordered = true
        item.target = target
        item.action = action
        return item
    }
}

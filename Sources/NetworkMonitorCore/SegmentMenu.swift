import AppKit

/// The menu a segmented toolbar control becomes when the window is too narrow
/// for it and it falls into the toolbar's » overflow (#309). A toolbar item
/// made from a view shows only its label there, and choosing it does nothing,
/// unless it's given a menu form: this one has an entry per segment, enabled
/// and ticked as the control is, and choosing one works as clicking it.
public enum SegmentMenu {

    /// `titles` names each segment in order, for segments that show only a
    /// symbol, or a tooltip that carries a shortcut.
    public static func item(for control: NSSegmentedControl, label: String, titles: [String]) -> NSMenuItem {
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: label)
        for (index, title) in titles.enumerated() where index < control.segmentCount {
            let entry = NSMenuItem(title: title, action: #selector(SegmentMenuTarget.chosen(_:)),
                                   keyEquivalent: "")
            entry.target = SegmentMenuTarget.shared
            entry.representedObject = Segment(control: control, index: index)
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    final class Segment: NSObject {
        weak var control: NSSegmentedControl?
        let index: Int

        init(control: NSSegmentedControl, index: Int) {
            self.control = control
            self.index = index
        }
    }
}

/// Answers the menu's entries: shared, since a menu item holds its target
/// weakly and the control it stands for is what each entry points at.
final class SegmentMenuTarget: NSObject, NSMenuItemValidation {

    static let shared = SegmentMenuTarget()

    @objc func chosen(_ sender: NSMenuItem) {
        guard let segment = sender.representedObject as? SegmentMenu.Segment,
              let control = segment.control else { return }
        // A momentary control (‹ Today ›) holds a selection only while it's
        // pressed, so it's held as a choice for the length of the action,
        // which reads the selected segment as a click's would.
        let tracking = control.trackingMode
        control.trackingMode = .selectOne
        control.selectedSegment = segment.index
        control.sendAction(control.action, to: control.target)
        if tracking != .selectOne {
            control.trackingMode = tracking
            control.selectedSegment = -1
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let segment = menuItem.representedObject as? SegmentMenu.Segment,
              let control = segment.control else { return false }
        menuItem.state = control.trackingMode == .selectOne && control.selectedSegment == segment.index
            ? .on : .off
        return control.isEnabled && control.isEnabled(forSegment: segment.index)
    }
}

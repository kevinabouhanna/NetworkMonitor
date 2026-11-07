import AppKit
import NetworkMonitorCore

/// Records what a segmented control sends, as a window controller would.
private final class Receiver: NSObject {
    var chosen: [Int] = []
    @objc func act(_ sender: NSSegmentedControl) { chosen.append(sender.selectedSegment) }
}

func runSegmentMenuTests() {
    Check.suite("SegmentMenu") {

        func control(_ mode: NSSegmentedControl.SwitchTracking, _ receiver: Receiver) -> NSSegmentedControl {
            let control = NSSegmentedControl()
            control.segmentCount = 3
            control.trackingMode = mode
            control.target = receiver
            control.action = #selector(Receiver.act(_:))
            return control
        }

        // #309: in the » overflow, ‹ Today › showed as "Go" and did nothing.
        Check.test("the overflow's Go has an entry per segment") {
            let receiver = Receiver()
            let item = SegmentMenu.item(for: control(.momentary, receiver), label: "Go",
                                        titles: ["Previous", "Today", "Next"])
            Check.expectEqual(item.title, "Go")
            Check.expectEqual(item.submenu?.items.map(\.title) ?? [], ["Previous", "Today", "Next"])
        }

        Check.test("choosing an entry works as clicking its segment") {
            let receiver = Receiver()
            let item = SegmentMenu.item(for: control(.momentary, receiver), label: "Go",
                                        titles: ["Previous", "Today", "Next"])
            item.submenu?.performActionForItem(at: 2)
            item.submenu?.performActionForItem(at: 0)
            Check.expectEqual(receiver.chosen, [2, 0])
        }

        Check.test("a segment that's off is an entry that's off") {
            let receiver = Receiver()
            let step = control(.momentary, receiver)
            step.setEnabled(false, forSegment: 2)
            let item = SegmentMenu.item(for: step, label: "Go", titles: ["Previous", "Today", "Next"])
            item.submenu?.update()
            Check.expectEqual(item.submenu?.items.map(\.isEnabled) ?? [], [true, true, false])
        }

        Check.test("the chosen period is ticked") {
            let receiver = Receiver()
            let scale = control(.selectOne, receiver)
            scale.selectedSegment = 1
            let item = SegmentMenu.item(for: scale, label: "Period", titles: ["Day", "Week", "Month"])
            item.submenu?.update()
            Check.expectEqual(item.submenu?.items.map(\.state) ?? [], [.off, .on, .off])
        }
    }
}

import NetworkMonitorCore

func runWindowStackTests() {
    Check.suite("WindowStack") {

        // The stack from #71, front to back: the popover on the status bar's
        // layer, then Chrome, Settings and iTerm2 as ordinary windows, and
        // Notification Center far below.
        let stack = [(number: 8312, layer: 25), (number: 225, layer: 0),
                     (number: 8314, layer: 0), (number: 4254, layer: 0),
                     (number: 45, layer: -2147483601)]

        Check.test("behind Chrome, Chrome is in front") {
            Check.expectEqual(WindowStack.window(inFrontOf: 8314, in: stack), 225)
        }

        // The popover is on another layer: ordering Settings below it would put
        // Settings over Chrome, the very thing #71 is about.
        Check.test("windows on other layers don't count") {
            Check.expectEqual(WindowStack.window(inFrontOf: 225, in: stack), nil)
        }

        Check.test("the nearest window in front, not the frontmost") {
            Check.expectEqual(WindowStack.window(inFrontOf: 4254, in: stack), 8314)
        }

        // Closed, minimised or on another Space: it isn't in the list.
        Check.test("a window that isn't on screen has nothing in front") {
            Check.expectEqual(WindowStack.window(inFrontOf: 9999, in: stack), nil)
        }
    }
}

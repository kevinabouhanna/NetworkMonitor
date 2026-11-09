// site-shots: keeps the website's pictures of the app current, without anyone
// looking at them.
//
// Each picture on the site has an entry in the site's `shots/shots.json`: the
// launch arguments that open its window, anything to click first, and which
// parts of the window are data rather than interface. For each entry it opens
// the installed app and reads the window's accessibility tree: roles, labels,
// sizes. Numbers, dates, settings' values and the regions marked as data are
// masked, so the tree changes only when the interface does. It compares that
// with the tree recorded when the picture was taken (`shots/trees/<name>.txt`):
//
//   check            reports what changed, and which videos or staged pictures
//                    show a window that changed (they're remade by hand)
//   update [names]   retakes the pictures whose window changed (or the ones
//                    named), records their trees, and updates the page: each
//                    picture's size, the clickable areas laid over it, and the
//                    `?v=` on every asset link
//   tree <name>      prints the masked tree, for writing an entry
//   audit [names]    checks each window for what VoiceOver can't name (#346),
//                    with the rules the tests use, but on real data: list
//                    rows, scanned apps, the popover with traffic
//
// It needs Accessibility and Screen Recording for the terminal it runs in. It
// quits and relaunches the installed app, and puts it back running at the end.
// Build with `make site-shots`; see docs/development.md#website-pictures.

import AppKit
import ApplicationServices
import CryptoKit
import ScreenCaptureKit

// MARK: - Manifest

struct Manifest: Decodable {
    var app: String
    var bundle: String
    var shots: [Shot]
    /// The site's assets this tool doesn't take: see `HandMade`.
    var assets: [HandMade]?
}

/// An image, GIF or video the pages use that isn't a shot's picture (#413).
/// Every asset a page uses must be either a shot's `file` or one of these, so
/// none can go stale unnoticed: `coverage` fails on any that isn't.
struct HandMade: Decodable {
    var file: String
    /// The shots whose windows it shows. When one changes, it's named for
    /// remaking by hand until that shot is updated by name.
    var shows: [String]?
    /// Or why it shows no window this tool can check: an icon, the menu bar.
    var none: String?
}

/// The README's and the docs' assets, in `Resources/README/assets.json` on
/// `main`, listed the same way.
struct RepoAssets: Decodable {
    var assets: [HandMade]
}

/// Where the main branch's list lives, relative to its checkout.
let repoAssetsPath = "Resources/README/assets.json"

struct Shot: Decodable {
    var name: String
    /// The picture, relative to the site. None for a window that's only
    /// checked, for the videos and staged pictures in `flags`.
    var file: String?
    var open: [String]
    /// The window's title, or an element to find in any of the app's windows,
    /// such as `AXPopover`.
    var window: String
    /// Elements to click, in order, once the window is open.
    var click: [String]?
    /// A scroll area to scroll to its end, after the clicks.
    var scroll: String?
    /// An element to wait for, after the clicks, such as a speed test's
    /// result: the spec, and how many seconds to wait at most.
    var waitFor: Wait?
    /// Taken only when the window of the shot named here changed in the same
    /// run, or when named: for a shot that costs something to take, such as a
    /// speed test, which must never run just to check.
    var when: String?
    /// Skipped, with a note, while this element is in the window: a speed
    /// test can't run on a hotspot, where the app asks before spending data.
    /// A `when` shot that's skipped is tried again on the next update.
    var skipIf: String?
    /// Elements left out of the tree altogether: lines that come and go with
    /// the Mac's state, such as Hotspot's "already in Low Data Mode".
    var ignore: [String]?
    /// Regions whose contents are data: each one's roles are kept, not its
    /// labels, sizes or how many rows it has.
    var data: [DataRegion]?
    /// Part of the window, found by its elements so it follows the layout.
    var crop: Crop?
    /// Clickable areas laid over the picture on the page, placed from the
    /// window's elements.
    var areas: [Area]?
    /// Retaken on every update, changed or not: About shows the version.
    var always: Bool?
    /// Videos and staged pictures that show this window. They're reported when
    /// it changes, for remaking by hand. The older way of saying what the
    /// manifest's `assets` say with `shows`; both work.
    var flags: [String]?
}

struct Wait: Decodable {
    var element: String
    var seconds: Double
}

struct DataRegion: Decodable {
    /// The element the region starts at, or starts `skip` siblings after:
    /// `skip: 1` marks the value beside a label, whatever it says.
    var from: String
    var skip: Int?
    /// The sibling that ends it (not included); "end" for the rest of its
    /// siblings; "run" for the siblings right after it with the same role, like
    /// a chart's bars. Absent, the region is the `from` element alone.
    var until: String?
}

struct Crop: Decodable {
    /// The element at the top, and the one at the bottom.
    var from: String
    var through: String
    /// Points left out on each side, and added above the top and below the
    /// bottom.
    var inset: Double
    var pad: [Double]

    /// The rectangle in the window, in points.
    func rect(in window: AXUIElement) throws -> CGRect {
        guard let w = frame(window), let top = find(from, in: window).flatMap(frame),
              let bottom = find(through, in: window).flatMap(frame) else { throw Failure("can't find \(from) or \(through) to crop to") }
        let y = top.minY - w.minY - pad[0]
        return CGRect(x: inset, y: y, width: w.width - 2 * inset, height: bottom.maxY - w.minY + pad[1] - y)
    }
}

struct Area: Decodable {
    /// Text that picks out the area's tag in index.html, e.g. `data-pane="ads"`.
    var match: String
    /// The element it covers.
    var element: String
    /// The element's parent instead, e.g. a whole row for its label.
    var parent: Bool?
    /// Points added on each side: horizontally, vertically.
    var pad: [Double]?
    /// A fixed height, in points.
    var h: Double?
}

// MARK: - Accessibility

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func text(_ element: AXUIElement, _ name: String) -> String? {
    switch attribute(element, name) {
    case let s as String: return s.isEmpty ? nil : s
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute) else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}

func role(_ element: AXUIElement) -> String { text(element, kAXRoleAttribute) ?? "?" }

func labels(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { text(element, $0) }
}

/// `Role` or `Role:label`, where the label is the start of the element's
/// title, description or value. `find` also takes `Outer>Inner`: an Inner
/// inside an Outer.
func matches(_ element: AXUIElement, _ spec: String) -> Bool {
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard role(element) == parts[0] else { return false }
    guard parts.count == 2 else { return true }
    // `Role:~text` matches text anywhere in the label, for a line that starts
    // with a number.
    if parts[1].hasPrefix("~") { return labels(element).contains { $0.contains(parts[1].dropFirst()) } }
    return labels(element).contains { $0.hasPrefix(parts[1]) }
}

func find(_ spec: String, in element: AXUIElement) -> AXUIElement? {
    if let split = spec.range(of: ">") {
        guard let outer = find(String(spec[..<split.lowerBound]), in: element) else { return nil }
        return children(outer).lazy.compactMap { find(String(spec[split.upperBound...]), in: $0) }.first
    }
    if matches(element, spec) { return element }
    for child in children(element) {
        if let found = find(spec, in: child) { return found }
    }
    return nil
}

func find(_ role: String, in element: AXUIElement, subrole: String) -> AXUIElement? {
    children(element).first { text($0, kAXRoleAttribute) == role && text($0, kAXSubroleAttribute) == subrole }
}

func parent(of element: AXUIElement) -> AXUIElement? {
    attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
}

// MARK: - The masked tree

/// Roles whose value is the user's setting rather than interface.
let settingRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXTextField",
                                 "AXTextArea", "AXComboBox", "AXDisclosureTriangle", "AXIncrementor", "AXValueIndicator"]

let months = "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec"
let weekdays = "Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|Mon|Tue|Wed|Thu|Fri|Sat|Sun"

func mask(_ s: String) -> String {
    var s = s.replacingOccurrences(of: "\\d[\\d.,:\u{202F}\u{00A0}]*", with: "#", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\b(\(months))\\b", with: "‹month›", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\b(\(weekdays))\\b", with: "‹day›", options: .regularExpression)
    s = s.replacingOccurrences(of: "#\\s?(AM|PM|am|pm)\\b", with: "‹time›", options: .regularExpression)
    // A total is in KB one day and GB the next.
    s = s.replacingOccurrences(of: "#\\s?(bytes|[KMGT]?B/s|[KMGT]bps|bps|[KMGT]?B)(?![A-Za-z])", with: "# ‹unit›",
                               options: .regularExpression)
    return s.replacingOccurrences(of: "\n", with: " ")
}

func rounded(_ v: CGFloat) -> Int { Int((v / 4).rounded()) * 4 }

/// One line per element: its role, its labels with numbers and dates masked,
/// and its size to the nearest 4 points. Positions are left out, since a list
/// above can push everything down; a text's width too, since a number's digits
/// change it.
func line(_ element: AXUIElement) -> String {
    let r = role(element)
    var parts = [r]
    if let sub = text(element, kAXSubroleAttribute) { parts.append("(\(sub))") }
    for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, kAXHelpAttribute] {
        if name == kAXValueAttribute && settingRoles.contains(r) { continue }
        if let s = text(element, name) { parts.append("\(name.dropFirst(2).lowercased())=\"\(mask(s))\"") }
    }
    if let f = frame(element) {
        let shown = settingRoles.contains(r) ? labels(element).dropLast(text(element, kAXValueAttribute) == nil ? 0 : 1) : labels(element)[...]
        let hasNumber = shown.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil }
        parts.append(r == "AXStaticText" || hasNumber || containerRoles.contains(r)
                     ? "h\(rounded(f.height))" : "\(rounded(f.width))x\(rounded(f.height))")
    }
    return parts.joined(separator: " ")
}

/// The distinct roles in a region, however many rows it has.
func roles(in elements: [AXUIElement]) -> [String] {
    var found = Set<String>()
    func walk(_ e: AXUIElement) {
        found.insert(role(e) + (text(e, kAXSubroleAttribute).map { "(\($0))" } ?? ""))
        children(e).forEach(walk)
    }
    elements.forEach(walk)
    return found.sorted()
}

/// Containers keep their height only: a scroll bar that comes with a longer
/// list narrows every one of them by its width.
let containerRoles: Set<String> = ["AXGroup", "AXScrollArea", "AXOpaqueProviderGroup", "AXList"]

/// Roles left out altogether: a scroll bar comes and goes with a list's length.
let ignoredRoles: Set<String> = ["AXScrollBar"]

func tree(_ window: AXUIElement, data: [DataRegion], ignore: [String] = []) -> [String] {
    var out: [String] = []
    /// Whether the element's subtree held a data region.
    @discardableResult
    func walk(_ element: AXUIElement, _ depth: Int) -> Bool {
        let pad = String(repeating: "  ", count: depth)
        let index = out.count
        out.append(pad + line(element))
        let kids = children(element).filter { kid in
            !ignoredRoles.contains(role(kid)) && !ignore.contains { matches(kid, $0) }
        }
        var holdsData = false
        var i = 0
        while i < kids.count {
            if let region = data.first(where: { matches(kids[i], $0.from) }) {
                if let skip = region.skip, skip > 0 {
                    // The label itself stays interface.
                    for k in i..<min(i + skip, kids.count) { if walk(kids[k], depth + 1) { holdsData = true } }
                    i += skip
                    guard i < kids.count else { break }
                }
                var end = i + 1
                if let until = region.until {
                    switch until {
                    case "end": end = kids.count
                    case "run": while end < kids.count && role(kids[end]) == role(kids[i]) { end += 1 }
                    default:    end = kids[(i + 1)...].firstIndex { matches($0, until) } ?? kids.count
                    }
                }
                out.append(pad + "  data: " + roles(in: Array(kids[i..<end])).joined(separator: " "))
                holdsData = true
                i = end
            } else {
                if walk(kids[i], depth + 1) { holdsData = true }
                i += 1
            }
        }
        // Whatever holds a data region grows with its rows: keep its width only.
        if holdsData {
            out[index] = out[index].replacingOccurrences(of: "(\\d+)x\\d+$", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: " h\\d+$", with: "", options: .regularExpression)
        }
        return holdsData
    }
    walk(window, 0)
    return out
}

// MARK: - The app

struct Session {
    let manifest: Manifest

    var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: manifest.bundle).first
    }

    func quit() {
        guard let app = running else { return }
        app.terminate()
        for _ in 0..<80 where running != nil { usleep(250_000) }
        if let app = running { app.forceTerminate(); usleep(500_000) }
        // `open` straight after a quit can fail with -600.
        sleep(2)
    }

    func launch(_ arguments: [String]) throws {
        quit()
        for attempt in 1...3 {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-a", manifest.app, "--args"] + arguments
            try open.run()
            open.waitUntilExit()
            for _ in 0..<40 where running == nil { usleep(250_000) }
            if running != nil { return }
            if attempt < 3 { sleep(2) }
        }
        throw Failure("\(manifest.app) didn't start")
    }

    func window(_ title: String) throws -> AXUIElement {
        guard let app = running else { throw Failure("the app isn't running") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<60 {
            let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
            let found = title.hasPrefix("AX") ? windows.lazy.compactMap { find(title, in: $0) }.first
                : windows.first { (text($0, kAXTitleAttribute) ?? "") == title }
            if let w = found {
                usleep(1_500_000)   // let it lay out and load
                return w
            }
            usleep(250_000)
        }
        throw Failure("no window \"\(title)\"")
    }

    func bringForward(_ window: AXUIElement) {
        guard let app = running else { return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<3 {
            AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            usleep(300_000)
        }
    }

    /// A click on the element, as a person would: SwiftUI's disclosure rows
    /// offer no accessibility action.
    func click(_ spec: String, in window: AXUIElement) throws {
        guard let element = appear(spec, in: window), let f = frame(element) else { throw Failure("nothing matches \(spec)") }
        // A click that lands while another app is in front only brings the
        // window forward. Where the element has a value, such as a disclosure
        // row's open or closed, try again until it changes.
        let before = text(element, kAXValueAttribute)
        // A button presses through accessibility, with no pointer involved,
        // which would close a popover by landing outside it.
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        if (actions as? [String] ?? []).contains(kAXPressAction),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            usleep(1_200_000)
            if before == nil || text(element, kAXValueAttribute) != before { return }
        }
        for _ in 0..<4 {
            bringForward(window)
            let point = CGPoint(x: f.minX + min(40, f.width / 2), y: f.midY)
            let saved = CGEvent(source: nil)?.location
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(60_000)
            }
            if let saved { CGWarpMouseCursorPosition(saved) }
            usleep(1_200_000)
            if before == nil || text(element, kAXValueAttribute) != before { return }
        }
        throw Failure("clicking \(spec) didn't change it")
    }

    /// Scrolls a list to its end, as far down as it goes.
    func scrollToEnd(_ spec: String, in window: AXUIElement) throws {
        guard let area = appear(spec, in: window) else { throw Failure("nothing matches \(spec)") }
        // A list short enough to show whole has no scroll bar, and is at its end.
        guard let bar = attribute(area, kAXVerticalScrollBarAttribute).map({ $0 as! AXUIElement }) else { return }
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, 1.0 as CFNumber)
        usleep(800_000)
    }

    /// The element, once it's there: a popover's rows arrive with the first
    /// sample, a moment after it opens.
    func appear(_ spec: String, in window: AXUIElement, seconds: Double = 15) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let found = find(spec, in: window) { usleep(500_000); return found }
            usleep(300_000)
        } while Date() < deadline
        return nil
    }

    func wait(for wait: Wait, in window: AXUIElement) throws {
        let deadline = Date().addingTimeInterval(wait.seconds)
        while Date() < deadline {
            if find(wait.element, in: window) != nil { usleep(800_000); return }
            usleep(500_000)
        }
        throw Failure("\(wait.element) didn't appear within \(Int(wait.seconds)) s")
    }

    /// Moves a window that's on a 1x screen onto a Retina one, which captures
    /// it at full resolution.
    func ensureRetina(_ window: AXUIElement) {
        guard let f = frame(window) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
        let here = NSScreen.screens.first { flipped($0.frame).contains(CGPoint(x: f.midX, y: f.minY + 10)) }
        guard here?.backingScaleFactor ?? 2 < 2, let retina = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else { return }
        var to = CGPoint(x: flipped(retina.visibleFrame).minX + 60, y: flipped(retina.visibleFrame).minY + 40)
        if let value = AXValueCreate(.cgPoint, &to) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            usleep(500_000)
        }
    }

    func capture(_ window: AXUIElement, crop: Crop?) async throws -> CGImage {
        guard let app = running, let f = frame(window) else { throw Failure("no window to capture") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier }
        // A window by its frame; a popover by the smallest window around it,
        // which is larger for the arrow and the shadow.
        let exact = candidates.min(by: { distance($0.frame, f) < distance($1.frame, f) }).flatMap { distance($0.frame, f) < 4 ? $0 : nil }
        let around = candidates.filter { $0.frame.insetBy(dx: -1, dy: -1).contains(f) }
            .min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        guard let target = exact ?? around else { throw Failure("can't find the window on screen") }
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width * 2)
        config.height = Int(target.frame.height * 2)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                               configuration: config)
        guard let crop else { return image }
        let r = try crop.rect(in: window)
        let rect = CGRect(x: (r.minX * 2).rounded(), y: (r.minY * 2).rounded(), width: (r.width * 2).rounded(), height: (r.height * 2).rounded())
        guard let cropped = image.cropping(to: rect) else { throw Failure("crop is outside the window") }
        return cropped
    }

    func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

/// A capture of an inactive window has grey traffic lights; the active one's
/// close button is red.
func isActive(_ image: CGImage, window: AXUIElement) -> Bool {
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
          let w = frame(window), let close = find("AXButton", in: window, subrole: "AXCloseButton").flatMap(frame) else { return true }
    let x = Int((close.midX - w.minX) * 2), y = Int((close.midY - w.minY) * 2)
    guard x < image.width, y < image.height else { return true }
    let i = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
    let first = Int(bytes[i]), third = Int(bytes[i + 2])
    let red = image.bitmapInfo.contains(.byteOrder32Little) ? third : first
    let blue = image.bitmapInfo.contains(.byteOrder32Little) ? first : third
    return red > 180 && blue < 120
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw Failure("can't write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("can't write \(url.path)") }
}

// MARK: - The page

struct Page {
    let url: URL
    var html: String

    init(site: URL) throws {
        url = site.appendingPathComponent("index.html")
        html = try String(contentsOf: url, encoding: .utf8)
    }

    func save() throws { try html.write(to: url, atomically: true, encoding: .utf8) }

    /// The whole tag containing `needle`.
    func tagRange(containing needle: String) -> Range<String.Index>? {
        guard let hit = html.range(of: needle),
              let start = html[..<hit.lowerBound].range(of: "<", options: .backwards),
              let end = html[hit.upperBound...].range(of: ">") else { return nil }
        return start.lowerBound..<end.upperBound
    }

    mutating func edit(tagContaining needle: String, _ change: (String) -> String) {
        guard let range = tagRange(containing: needle) else { return }
        html.replaceSubrange(range, with: change(String(html[range])))
    }

    static func set(_ attribute: String, _ value: String, in tag: String) -> String {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: attribute))=\"[^\"]*\""
        return tag.range(of: pattern, options: .regularExpression) == nil ? tag
            : tag.replacingOccurrences(of: pattern, with: "\(attribute)=\"\(value)\"", options: .regularExpression)
    }

    /// `width` and `height` in pixels, and `data-w` and `data-h` in points
    /// where the tag has them.
    /// Every tag containing `needle`, last first so the ranges stay good.
    mutating func editAll(tagsContaining needle: String, _ change: (String) -> String) {
        var ranges: [Range<String.Index>] = []
        var from = html.startIndex
        while let hit = html.range(of: needle, range: from..<html.endIndex) {
            if let start = html[..<hit.lowerBound].range(of: "<", options: .backwards),
               let end = html[hit.upperBound...].range(of: ">") {
                ranges.append(start.lowerBound..<end.upperBound)
            }
            from = hit.upperBound
        }
        for range in ranges.reversed() { html.replaceSubrange(range, with: change(String(html[range]))) }
    }

    /// The picture's size, on every `<img>` that shows it: one picture can
    /// be in two sections.
    mutating func setSize(of file: String, pixels: CGSize) {
        editAll(tagsContaining: "\"\(file)") { tag in
            var tag = Page.set("width", "\(Int(pixels.width))", in: tag)
            tag = Page.set("height", "\(Int(pixels.height))", in: tag)
            tag = Page.set("data-w", "\(Int(pixels.width / 2))", in: tag)
            return Page.set("data-h", "\(Int(pixels.height / 2))", in: tag)
        }
    }

    /// An area's `--x` (from the window's centre), `--y`, `--w` and `--h`.
    mutating func place(_ area: Area, at r: CGRect, windowWidth: CGFloat) {
        let padX = area.pad?.first ?? 0, padY = area.pad?.last ?? 0
        let values = ["--x": r.minX - padX - windowWidth / 2, "--y": r.minY - padY,
                      "--w": r.width + 2 * padX, "--h": area.h ?? (r.height + 2 * padY)]
        edit(tagContaining: area.match) { tag in
            var tag = tag
            for (name, v) in values {
                tag = tag.replacingOccurrences(of: "\(name):-?[\\d.]+", with: "\(name):\(Int(v.rounded()))", options: .regularExpression)
            }
            return tag
        }
    }

    /// `?v=` and the first eight hex digits of each asset's contents, on every
    /// link to it, so a page never shows a picture the browser kept from an
    /// older version.
    mutating func stampAssets(site: URL) {
        let regex = try! NSRegularExpression(pattern: "(assets/[A-Za-z0-9_./-]+\\.(?:png|jpg|jpeg|gif|webp|svg|mp4|webm))(\\?v=[0-9a-f]+)?")
        let ns = html as NSString
        var result = "", last = 0
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let data = try? Data(contentsOf: site.appendingPathComponent(path)) {
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(8)
                result += "\(path)?v=\(hash)"
            } else {
                result += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        html = result + ns.substring(from: last)
    }
}

// MARK: - Coverage

/// Every image, GIF and video the pages use, each with the pages using it,
/// checked against the lists (#413). Reads files only: no app, no
/// Accessibility, so it runs in CI.
enum Coverage {
    static let media = "png|jpe?g|gif|webp|svg|mp4|webm|mov"

    /// The site's own assets: `assets/…`, as a relative link or on the site's
    /// own address (the social preview's `<meta>` tags). Another site's
    /// `/assets/` isn't ours.
    static func siteUses(_ site: URL) throws -> [String: Set<String>] {
        let regex = try NSRegularExpression(
            pattern: #"(?:^|["'(=,\s]|github\.io/NetworkMonitor/)(assets/[A-Za-z0-9_./-]+\.(?:"# + media + #"))"#,
            options: [.caseInsensitive, .anchorsMatchLines])
        var uses: [String: Set<String>] = [:]
        let pages = try FileManager.default.contentsOfDirectory(atPath: site.path)
            .filter { $0.hasSuffix(".html") }.sorted()
        for page in pages {
            let text = try String(contentsOf: site.appendingPathComponent(page), encoding: .utf8)
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                uses[ns.substring(with: m.range(at: 1)), default: []].insert(page)
            }
        }
        return uses
    }

    /// The README's, SECURITY's and the docs' local media, as paths from the
    /// checkout's root.
    static func repoUses(_ repo: URL) throws -> [String: Set<String>] {
        let regex = try NSRegularExpression(
            pattern: #"(?:(?:src|poster)\s*=\s*["']([^"']+)["']|!\[[^\]]*\]\(\s*<?([^)\s>]+))"#)
        let mediaRegex = try NSRegularExpression(pattern: #"\.(?:"# + media + #")$"#, options: .caseInsensitive)
        var pages = ["README.md", "SECURITY.md"]
        // Every page under docs/, its folders' too, such as the design log's (#437).
        let docs = FileManager.default.enumerator(atPath: repo.appendingPathComponent("docs").path)?
            .compactMap { $0 as? String } ?? []
        pages += docs.filter { $0.hasSuffix(".md") }.sorted().map { "docs/" + $0 }
        var uses: [String: Set<String>] = [:]
        for page in pages {
            guard let text = try? String(contentsOf: repo.appendingPathComponent(page), encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
                var link = ns.substring(with: r)
                if link.contains("://") || link.hasPrefix("#") || link.hasPrefix("data:") { continue }
                link = link.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
                let lns = link as NSString
                guard mediaRegex.firstMatch(in: link, range: NSRange(location: 0, length: lns.length)) != nil else { continue }
                // Relative to the page, as GitHub reads it.
                let base = repo.appendingPathComponent(page).deletingLastPathComponent()
                let full = URL(fileURLWithPath: link, relativeTo: base).standardizedFileURL.path
                let root = repo.standardizedFileURL.path + "/"
                guard full.hasPrefix(root) else { continue }
                uses[String(full.dropFirst(root.count)), default: []].insert(page)
            }
        }
        return uses
    }

    /// What's wrong, one line each; empty when every asset is accounted for.
    static func problems(manifest: Manifest, site: URL, repoAssets: RepoAssets?, repo: URL?) throws -> (problems: [String], summary: String) {
        var problems: [String] = []
        let shotNames = Set(manifest.shots.map(\.name))

        func checkList(_ list: [HandMade], root: URL, listName: String, uses: [String: Set<String>], taken: Set<String>) {
            var seen = Set<String>()
            for asset in list {
                let file = asset.file
                if !seen.insert(file).inserted { problems.append("\(file) is listed twice in \(listName)") }
                if taken.contains(file) { problems.append("\(file) is a shot's picture; take it out of \(listName)'s assets") }
                let shows = asset.shows ?? []
                if shows.isEmpty == (asset.none == nil) {
                    problems.append("\(file) in \(listName) needs either `shows` (the windows it shows) or `none` (why it shows none), not both")
                }
                for name in shows where !shotNames.contains(name) {
                    problems.append("\(file) in \(listName) shows \"\(name)\", which isn't a shot in shots/shots.json")
                }
                if !FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) {
                    problems.append("\(file) is listed in \(listName) but doesn't exist")
                } else if uses[file] == nil {
                    problems.append("\(file) is listed in \(listName) but no page uses it; take it out")
                }
            }
            for (file, pages) in uses.sorted(by: { $0.key < $1.key }) where !taken.contains(file) && !seen.contains(file) {
                problems.append("\(file) (\(pages.sorted().joined(separator: ", "))) isn't listed. Add it to \(listName)'s "
                                + "`assets` with the shots whose windows it `shows`, or `none` and why it shows none")
            }
        }

        // The site: each asset is a shot's picture, a flag, or listed.
        let siteUses = try siteUses(site)
        let shotFiles = Set(manifest.shots.compactMap(\.file))
        for shot in manifest.shots {
            if let file = shot.file, !FileManager.default.fileExists(atPath: site.appendingPathComponent(file).path) {
                problems.append("\(file), \(shot.name)'s picture, doesn't exist")
            }
        }
        let flagged = manifest.shots.flatMap { shot in (shot.flags ?? []).map { HandMade(file: $0, shows: [shot.name]) } }
        checkList((manifest.assets ?? []) + flagged.filter { f in !(manifest.assets ?? []).contains { $0.file == f.file } },
                  root: site, listName: "shots/shots.json", uses: siteUses, taken: shotFiles)
        var summary = "\(siteUses.count) assets on the site"

        // The README and the docs.
        if let repo {
            let uses = try repoUses(repo)
            checkList(repoAssets?.assets ?? [], root: repo, listName: repoAssetsPath, uses: uses, taken: [])
            summary += " and \(uses.count) in the README and docs"
        }
        return (problems, summary)
    }
}

// MARK: - Running

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func diff(_ old: [String], _ new: [String]) -> [String] {
    let o = Set(old), n = Set(new)
    return old.filter { !n.contains($0) }.map { "  - " + $0.trimmingCharacters(in: .whitespaces) }
        + new.filter { !o.contains($0) }.map { "  + " + $0.trimmingCharacters(in: .whitespaces) }
}

@main
struct SiteShots {
    static func main() async {
        _ = NSApplication.shared   // ScreenCaptureKit needs a connection to the window server
        var args = Array(CommandLine.arguments.dropFirst())
        var site = URL(fileURLWithPath: "../NetworkMonitor-site")
        if let i = args.firstIndex(of: "--site"), i + 1 < args.count {
            site = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
        }
        // The main checkout, for the README's and the docs' assets: this one.
        var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let i = args.firstIndex(of: "--repo"), i + 1 < args.count {
            repo = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
        }
        guard let command = args.first, ["check", "update", "tree", "audit", "coverage"].contains(command) else {
            print("usage: site-shots check|update|audit [names…]|tree <name>|coverage [--site DIR] [--repo DIR]")
            exit(2)
        }
        let names = Set(args.dropFirst())
        let repoAssets = try? JSONDecoder().decode(RepoAssets.self, from: Data(contentsOf: repo.appendingPathComponent(repoAssetsPath)))

        // Files only, so first, before anything that needs the app.
        if command == "coverage" {
            do {
                let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: site.appendingPathComponent("shots/shots.json")))
                if repoAssets == nil, FileManager.default.fileExists(atPath: repo.appendingPathComponent(repoAssetsPath).path) {
                    throw Failure("\(repoAssetsPath) doesn't read as a list of assets")
                }
                let found = try Coverage.problems(manifest: manifest, site: site, repoAssets: repoAssets, repo: repo)
                if found.problems.isEmpty {
                    print("coverage: \(found.summary), all accounted for")
                    exit(0)
                }
                print("coverage: every image, GIF and video a page uses must be listed, so a change to the window it shows can't leave it stale (#413):")
                found.problems.forEach { print("  " + $0) }
                exit(1)
            } catch {
                print("coverage: \(error)")
                exit(2)
            }
        }
        // One run at a time: each quits and relaunches the app, so two at once,
        // from two terminals or two sessions, spoil each other's windows.
        let lock = open(NSHomeDirectory() + "/Library/Caches/site-shots.lock", O_CREAT | O_RDWR, 0o644)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            print("site-shots: another run is driving the app; try again once it's done")
            exit(2)
        }
        do {
            guard AXIsProcessTrusted() else { throw Failure("give this terminal Accessibility in System Settings › Privacy & Security") }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: site.appendingPathComponent("shots/shots.json")))
            let session = Session(manifest: manifest)
            let wasRunning = session.running != nil
            let status: Int32
            do { status = try await run(command, names: names, manifest: manifest, session: session, site: site, repoAssets: repoAssets) }
            catch { status = 2; print("site-shots: \(error)") }
            // Put the app back as it was.
            if wasRunning { try? session.launch([]) } else { session.quit() }
            exit(status)
        } catch {
            print("site-shots: \(error)")
            exit(2)
        }
    }

    static func run(_ command: String, names: Set<String>, manifest: Manifest, session: Session, site: URL,
                    repoAssets: RepoAssets?) async throws -> Int32 {
        let shots = manifest.shots.filter { names.isEmpty || names.contains($0.name) }
        if shots.isEmpty { throw Failure("no shot named \(names.sorted().joined(separator: ", "))") }
        let trees = site.appendingPathComponent("shots/trees")
        try FileManager.default.createDirectory(at: trees, withIntermediateDirectories: true)
        var page = try Page(site: site)
        var changed: [String] = [], flagged: [String] = [], failed: [String] = []
        var problems: [String] = []
        var cached: (args: [String], window: String)?

        // What's made by hand from each window, on the site and in the README
        // and docs (#413), to name when the window changes.
        var handMade: [String: [String]] = [:]
        for shot in manifest.shots { handMade[shot.name, default: []] += shot.flags ?? [] }
        for asset in manifest.assets ?? [] {
            for name in asset.shows ?? [] where !(handMade[name] ?? []).contains(asset.file) { handMade[name, default: []].append(asset.file) }
        }
        for asset in repoAssets?.assets ?? [] {
            for name in asset.shows ?? [] { handMade[name, default: []].append("\(asset.file) (main)") }
        }

        var current: [String: [String]] = [:]
        for shot in shots {
            do {
                // A costly shot follows its base window: retaken only when the
                // base's tree differs from the one it was last taken with.
                var baseTree: [String]?
                if let base = shot.when {
                    let baseFile = trees.appendingPathComponent("\(shot.name).base.txt")
                    let taken = (try? String(contentsOf: baseFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
                    guard let now = current[base] else {
                        print("\(shot.name): needs \(base) checked first, in the same run"); continue
                    }
                    let named = names.contains(shot.name)
                    if taken == now && !named { print("\(shot.name): unchanged (\(base) is)"); continue }
                    if command != "update" || (taken != nil && !named && command == "check") {
                        print("\(shot.name): \(base) changed, so it's retaken on update")
                        changed.append(shot.name); continue
                    }
                    if command != "update" { continue }
                    baseTree = now
                }
                // Shots that open the same window without clicks share a launch.
                if cached?.args != shot.open || cached?.window != shot.window || shot.click != nil {
                    cached = nil
                    try session.launch(shot.open)
                    cached = (shot.open, shot.window)
                }
                // Once more from a fresh launch if it doesn't show: a popover
                // now and then doesn't open on the first try.
                var window: AXUIElement
                do { window = try session.window(shot.window) } catch {
                    try session.launch(shot.open)
                    window = try session.window(shot.window)
                }
                if let spec = shot.skipIf, find(spec, in: window) != nil {
                    print("\(shot.name): skipped while \(spec) shows; it's tried again on the next update")
                    cached = nil
                    continue
                }
                if shot.click != nil { cached = nil }
                for spec in shot.click ?? [] { try session.click(spec, in: window) }
                if let spec = shot.scroll { try session.scrollToEnd(spec, in: window) }
                if let wait = shot.waitFor { try session.wait(for: wait, in: window) }
                // A click can rebuild what was clicked in, such as a popover
                // that grows: find the window again.
                if shot.click != nil || shot.scroll != nil { window = try session.window(shot.window) }
                // Read it once it has settled: lists and charts fill in a
                // moment after the window opens.
                var now = tree(window, data: shot.data ?? [], ignore: shot.ignore ?? [])
                for _ in 0..<12 {
                    usleep(700_000)
                    let again = tree(window, data: shot.data ?? [], ignore: shot.ignore ?? [])
                    if again == now { break }
                    now = again
                }
                current[shot.name] = now
                if command == "tree" { print(now.joined(separator: "\n")); continue }
                if command == "audit" {
                    let found = AccessibilityAudit.audit(window).map { "\(shot.window): \($0)" }
                    print("\(shot.name): " + (found.isEmpty ? "nothing missing" : "\(found.count) to fix"))
                    problems += found
                    continue
                }

                let treeFile = trees.appendingPathComponent("\(shot.name).txt")
                let before = (try? String(contentsOf: treeFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
                let differs = before != now
                if let before, differs {
                    print("\(shot.name): the interface changed")
                    diff(before, now).prefix(40).forEach { print($0) }
                    changed.append(shot.name)
                } else {
                    print(differs ? "\(shot.name): no tree recorded yet" : "\(shot.name): unchanged")
                }
                let named = names.contains(shot.name)
                // What's made by hand from this window is compared with the
                // tree it was made from: retaking the window's own picture
                // doesn't remake them, so it doesn't end the reminder. Only an
                // update by the window's name does, once they're remade.
                let hand = handMade[shot.name] ?? []
                let madeFile = trees.appendingPathComponent("\(shot.name).made.txt")
                let made = (try? String(contentsOf: madeFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? before
                if !hand.isEmpty, let made, made != now, !(command == "update" && named) {
                    flagged += hand.map { "\($0), from \(shot.name)" }
                }
                guard command == "update", differs || named || shot.always == true || baseTree != nil else { continue }
                // A window that only flags videos keeps its old tree until
                // they're remade and it's updated by name, so the reminder stays.
                if shot.file == nil, before != nil, !named { continue }

                if let file = shot.file {
                    session.ensureRetina(window)
                    var image = try await session.capture(window, crop: shot.crop)
                    // A crop leaves out the traffic lights that tell.
                    let cropped = shot.crop != nil
                    for _ in 0..<4 where !cropped && !isActive(image, window: window) {
                        session.bringForward(window)
                        image = try await session.capture(window, crop: shot.crop)
                    }
                    if !cropped && !isActive(image, window: window) { print("  warning: \(file) shows the window inactive") }
                    try writePNG(image, to: site.appendingPathComponent(file))
                    page.setSize(of: file, pixels: CGSize(width: image.width, height: image.height))
                    print("  retook \(file) (\(image.width)×\(image.height))")
                }
                let windowFrame = frame(window) ?? .zero
                for area in shot.areas ?? [] {
                    guard var element = find(area.element, in: window) else { print("  warning: no \(area.element) for \(area.match)"); continue }
                    if area.parent == true, let p = parent(of: element) { element = p }
                    guard let r = frame(element) else { continue }
                    page.place(area, at: r.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY), windowWidth: windowFrame.width)
                }
                if !hand.isEmpty {
                    if named {
                        try (now.joined(separator: "\n") + "\n").write(to: madeFile, atomically: true, encoding: .utf8)
                    } else if !FileManager.default.fileExists(atPath: madeFile.path), let before {
                        try (before.joined(separator: "\n") + "\n").write(to: madeFile, atomically: true, encoding: .utf8)
                    }
                }
                try (now.joined(separator: "\n") + "\n").write(to: treeFile, atomically: true, encoding: .utf8)
                if let baseTree {
                    try (baseTree.joined(separator: "\n") + "\n").write(
                        to: trees.appendingPathComponent("\(shot.name).base.txt"), atomically: true, encoding: .utf8)
                }
                // Saved as it goes, so a later failure doesn't leave a picture
                // without its size and areas.
                try page.save()
            } catch {
                print("\(shot.name): \(error)")
                failed.append(shot.name)
                cached = nil
            }
        }

        if command == "update" {
            page.stampAssets(site: site)
            try page.save()
        }
        if !flagged.isEmpty {
            print("\nThese show a window that changed since they were made. Remake them by hand, then run `update` with the window's name:")
            Set(flagged).sorted().forEach { print("  \($0)") }
        }
        if command == "audit", !problems.isEmpty {
            // The same row repeats down a list; say it once.
            var seen = Set<String>()
            print("\nFor VoiceOver:")
            for p in problems where seen.insert(p).inserted { print("  " + p) }
        }
        if !failed.isEmpty { return 2 }
        if command == "audit" { return problems.isEmpty ? 0 : 1 }
        return command == "check" && !(changed.isEmpty && flagged.isEmpty) ? 1 : 0
    }
}

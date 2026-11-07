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
}

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
    /// it changes, for remaking by hand.
    var flags: [String]?
}

struct DataRegion: Decodable {
    /// The first element of the region.
    var from: String
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
/// title, description or value.
func matches(_ element: AXUIElement, _ spec: String) -> Bool {
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    guard role(element) == parts[0] else { return false }
    return parts.count == 1 || labels(element).contains { $0.hasPrefix(parts[1]) }
}

func find(_ spec: String, in element: AXUIElement) -> AXUIElement? {
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
        parts.append(r == "AXStaticText" || hasNumber ? "h\(rounded(f.height))" : "\(rounded(f.width))x\(rounded(f.height))")
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

/// Roles left out altogether: a scroll bar comes and goes with a list's length.
let ignoredRoles: Set<String> = ["AXScrollBar"]

func tree(_ window: AXUIElement, data: [DataRegion]) -> [String] {
    var out: [String] = []
    /// Whether the element's subtree held a data region.
    @discardableResult
    func walk(_ element: AXUIElement, _ depth: Int) -> Bool {
        let pad = String(repeating: "  ", count: depth)
        let index = out.count
        out.append(pad + line(element))
        let kids = children(element).filter { !ignoredRoles.contains(role($0)) }
        var holdsData = false
        var i = 0
        while i < kids.count {
            if let region = data.first(where: { matches(kids[i], $0.from) }) {
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
        guard let element = find(spec, in: window), let f = frame(element) else { throw Failure("nothing matches \(spec)") }
        bringForward(window)
        let point = CGPoint(x: f.minX + min(40, f.width / 2), y: f.midY)
        let saved = CGEvent(source: nil)?.location
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
        if let saved { CGWarpMouseCursorPosition(saved) }
        usleep(1_200_000)
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
        guard let target = candidates.min(by: { distance($0.frame, f) < distance($1.frame, f) }),
              distance(target.frame, f) < 4 else { throw Failure("can't find the window on screen") }
        let config = SCStreamConfiguration()
        config.width = Int(f.width * 2)
        config.height = Int(f.height * 2)
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

    /// The picture's size: `width` and `height` in pixels, and `data-w` and
    /// `data-h` in points where the tag has them.
    mutating func setSize(of file: String, pixels: CGSize) {
        edit(tagContaining: "\"\(file)") { tag in
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
        guard let command = args.first, ["check", "update", "tree"].contains(command) else {
            print("usage: site-shots check|update [names…]|tree <name> [--site DIR]")
            exit(2)
        }
        let names = Set(args.dropFirst())
        do {
            guard AXIsProcessTrusted() else { throw Failure("give this terminal Accessibility in System Settings › Privacy & Security") }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: site.appendingPathComponent("shots/shots.json")))
            let session = Session(manifest: manifest)
            let wasRunning = session.running != nil
            let status: Int32
            do { status = try await run(command, names: names, manifest: manifest, session: session, site: site) }
            catch { status = 2; print("site-shots: \(error)") }
            // Put the app back as it was.
            if wasRunning { try? session.launch([]) } else { session.quit() }
            exit(status)
        } catch {
            print("site-shots: \(error)")
            exit(2)
        }
    }

    static func run(_ command: String, names: Set<String>, manifest: Manifest, session: Session, site: URL) async throws -> Int32 {
        let shots = manifest.shots.filter { names.isEmpty || names.contains($0.name) }
        if shots.isEmpty { throw Failure("no shot named \(names.sorted().joined(separator: ", "))") }
        let trees = site.appendingPathComponent("shots/trees")
        try FileManager.default.createDirectory(at: trees, withIntermediateDirectories: true)
        var page = try Page(site: site)
        var changed: [String] = [], flagged: [String] = [], failed: [String] = []
        var cached: (args: [String], window: String)?

        for shot in shots {
            do {
                // Shots that open the same window without clicks share a launch.
                if cached?.args != shot.open || cached?.window != shot.window || shot.click != nil {
                    cached = nil
                    try session.launch(shot.open)
                    cached = (shot.open, shot.window)
                }
                let window = try session.window(shot.window)
                if shot.click != nil { cached = nil }
                for spec in shot.click ?? [] { try session.click(spec, in: window) }
                let now = tree(window, data: shot.data ?? [])
                if command == "tree" { print(now.joined(separator: "\n")); continue }

                let treeFile = trees.appendingPathComponent("\(shot.name).txt")
                let before = (try? String(contentsOf: treeFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
                let differs = before != now
                if let before, differs {
                    print("\(shot.name): the interface changed")
                    diff(before, now).prefix(40).forEach { print($0) }
                    changed.append(shot.name)
                    flagged += shot.flags ?? []
                } else {
                    print(differs ? "\(shot.name): no tree recorded yet" : "\(shot.name): unchanged")
                }
                let named = names.contains(shot.name)
                guard command == "update", differs || named || shot.always == true else { continue }
                // A window that only flags videos keeps its old tree until
                // they're remade and it's updated by name, so the reminder stays.
                if shot.file == nil, before != nil, !named { continue }

                if let file = shot.file {
                    session.ensureRetina(window)
                    var image = try await session.capture(window, crop: shot.crop)
                    for _ in 0..<4 where !isActive(image, window: window) {
                        session.bringForward(window)
                        image = try await session.capture(window, crop: shot.crop)
                    }
                    if !isActive(image, window: window) { print("  warning: \(file) shows the window inactive") }
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
                try (now.joined(separator: "\n") + "\n").write(to: treeFile, atomically: true, encoding: .utf8)
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
            print("\nThese show a window that changed. Remake them by hand, then run `update` with the window's name:")
            Set(flagged).sorted().forEach { print("  \($0)") }
        }
        if !failed.isEmpty { return 2 }
        return command == "check" && !changed.isEmpty ? 1 : 0
    }
}

// shots-kit: keeps a website's pictures of a macOS app current, without anyone
// looking at them. Part of product-kit (kevinabouhanna/product-kit#6); it grew
// out of NetworkMonitor's site-shots (NetworkMonitor#329), whose issues the
// notes below name.
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
//                    show a window that changed (they're remade by hand).
//                    With --look, and on `update`, also as advice the windows
//                    that look different from their pictures, outside what's
//                    masked (`<name>.look`)
//   update [names]   retakes the pictures whose window changed (or the ones
//                    named), records their trees, and updates the page: each
//                    picture's size, the clickable areas laid over it, and the
//                    `?v=` on every asset link
//   tree <name>      prints the masked tree, for writing an entry
//   audit [names]    checks each window for what VoiceOver can't name, on
//                    real data: list rows, the popover with traffic
//   readme           copies the site's pictures the README uses into it, in
//                    every language. Files only. `update` copies each one it
//                    retakes
//   record <names>   records the named windows' trees as they read now,
//                    without retaking their pictures: after marking more of
//                    a window as data or ignored. And keeps each picture's
//                    look from the picture as it is
//   coverage         every image, GIF and video the site, the README and the
//                    docs use is a shot's picture or listed with the windows
//                    it shows. Files only, so it runs in CI
//   coverage-test    where `coverage` looks for media, on made-up pages
//   version
//
// What's particular to a project is in its `.product-kit.json` (`--repo`, the
// current folder by default): `shots` (see `Config`) and `site.url`. A project
// with no website keeps `shots/shots.json` in its own checkout (product-kit#8).
//
// Or the project draws its pictures itself (product-kit#8): the manifest's
// `render` builds it and runs a command that writes each picture, out of sight,
// from fixed data. Then `check` compares each drawing with its picture, pixel
// by pixel, and `update` copies the ones that differ: no app, no screen, no
// lanes. See `Rendered`.
//
// It needs Accessibility and Screen Recording for the terminal it runs in. It
// takes the app's Mac lane and `screen` itself (mac-lane, from the shared-mac
// plugin), only while it reads or takes windows. A shot that needs a window
// brought forward or a real click while someone is using the Mac isn't taken:
// it's reported as not taken, and why, and never waited on unless asked
// (`--wait-away MINUTES`: silently, with the lanes free). Nobody is ever asked
// to step away. It quits and relaunches the app, and whenever it lets the
// lanes go, however the run ends, puts the installed copy back running if it
// was.
//
// Build: swiftc -O -parse-as-library shots-kit.swift AccessibilityAudit.swift
// (`shots-kit` in product-kit does it, and keeps the build), with the project's
// own AccessibilityAudit.swift when it has one (`shots.audit`).

import AppKit
import ApplicationServices
import CryptoKit
import ScreenCaptureKit

let shotsKitVersion = "1.1.0"

// MARK: - Config

/// What's particular to a project: `shots` in its `.product-kit.json`, and
/// the site's address from `site.url`. Every key is optional.
struct Config {
    /// The site's checkout, from the project's main checkout (so the same from
    /// any worktree): `../NetworkMonitor-site`. `--site` overrides it.
    var site: String?
    /// The README's and the docs' list of their assets, in the repo.
    var repoAssets = "assets.json"
    /// The app's Mac lane; the bundle id's last part, lowercased, by default.
    var lane: String?
    /// Launch arguments that open windows behind the others without
    /// activating the app, for commands that only read the tree.
    var background: [String] = []
    /// Launch arguments that show the app in a language; `{code}` is its code.
    var language = ["-AppleLanguages", "({code})"]
    /// The app's table for a language, in its bundle; `{code}` is its code.
    var strings = "Contents/Resources/{code}.lproj/Localizable.strings"
    /// The site's address: links to its assets written with it are the site's.
    var siteURL: String?
    /// The branches the site and the repo are on, for the asset check's report.
    var siteBranch = "gh-pages"
    var repoBranch = "main"

    static func load(repo: URL) -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: repo.appendingPathComponent(".product-kit.json")),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        c.siteURL = (top["site"] as? [String: Any])?["url"] as? String
        guard let shots = top["shots"] as? [String: Any] else { return c }
        c.site = shots["site"] as? String
        if let v = shots["repo_assets"] as? String { c.repoAssets = v }
        c.lane = shots["lane"] as? String
        let launch = shots["launch"] as? [String: Any]
        if let v = launch?["background"] as? [String] { c.background = v }
        if let v = launch?["language"] as? [String] { c.language = v }
        if let v = shots["strings"] as? String { c.strings = v }
        let branches = shots["branches"] as? [String: String]
        if let v = branches?["site"] { c.siteBranch = v }
        if let v = branches?["repo"] { c.repoBranch = v }
        return c
    }
}

nonisolated(unsafe) var config = Config()
/// The project's checkout (`--repo`).
nonisolated(unsafe) var repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// MARK: - Manifest

struct Manifest: Decodable {
    var app: String
    var bundle: String
    var shots: [Shot]
    /// The site's assets this tool doesn't take: see `HandMade`.
    var assets: [HandMade]?
    /// The other languages the site has a page in (NetworkMonitor#431). Each shot is taken
    /// again in each, for its page.
    var languages: [Language]?
    /// Pictures the project draws itself (product-kit#8): no app or window to
    /// open, so its shots name only their `file` and their `render`.
    var render: Render?

    enum CodingKeys: String, CodingKey { case app, bundle, shots, assets, languages, render }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assets = try c.decodeIfPresent([HandMade].self, forKey: .assets)
        languages = try c.decodeIfPresent([Language].self, forKey: .languages)
        render = try c.decodeIfPresent(Render.self, forKey: .render)
        if render != nil {
            app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
            bundle = try c.decodeIfPresent(String.self, forKey: .bundle) ?? ""
            shots = try c.decode([Rendered.Shot].self, forKey: .shots).map {
                Shot(name: $0.name, file: $0.file, open: [], window: "", render: $0.render)
            }
        } else {
            app = try c.decode(String.self, forKey: .app)
            bundle = try c.decode(String.self, forKey: .bundle)
            shots = try c.decode([Shot].self, forKey: .shots)
        }
    }
}

/// `shots/shots.json`: on the site, or in the project's checkout when it has no
/// site (product-kit#8).
func loadManifest(_ site: URL) throws -> Manifest {
    let file = site.appendingPathComponent("shots/shots.json")
    guard FileManager.default.fileExists(atPath: file.path) else {
        throw Failure(manifestInRepo
            ? "no shots/shots.json: put it in the project's checkout, or say where the site is (shots.site in .product-kit.json, or --site)"
            : "no shots/shots.json in \(site.path)")
    }
    return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
}

/// The project has no site: the manifest and its pictures are in its checkout,
/// and the README's and the docs' assets are listed in it (product-kit#8).
nonisolated(unsafe) var manifestInRepo = false

/// A language the site has a page in (NetworkMonitor#431). Its pictures are taken from the
/// app shown in that language (`-language`), into a folder of their own, for
/// its page; their trees are kept apart too. Element specs are translated with
/// the app's own table, so the manifest names each element once, in English.
struct Language: Decodable {
    /// The app's code for it: `zh-Hans`.
    var code: String
    /// Its page, from the site's root: `zh/index.html`.
    var page: String
    /// Where its pictures go: `assets/zh-Hans/`, the English one's path after it.
    var assets: String
    /// Labels in specs the table can't translate, because a spec names only
    /// the start of one (`This connection was already`) or a part (`~on metered
    /// connections`): the English as written in the spec, to this language's.
    var specs: [String: String]?

    /// From its page's folder back to the site's root: `../` for `zh/index.html`.
    var up: String { String(repeating: "../", count: page.split(separator: "/").count - 1) }

    /// Where it keeps its copy of an English picture.
    func file(_ english: String) -> String {
        english.hasPrefix("assets/") ? assets + english.dropFirst("assets/".count) : english
    }
}

/// Element specs and window titles in another language, from the app's table
/// for it (`<code>.lproj/Localizable.strings` in the app), and the language's
/// `specs` for what the table can't say.
final class Translator {
    let table: [String: String]
    let overrides: [String: String]
    /// Labels found in neither, which stay English: report them.
    private(set) var missing: Set<String> = []

    init(app: String, language: Language) throws {
        let url = URL(fileURLWithPath: app).appendingPathComponent(config.strings.replacingOccurrences(of: "{code}", with: language.code))
        guard let table = NSDictionary(contentsOf: url) as? [String: String] else {
            throw Failure("\(app) has no \(language.code) table; is it a version with that language?")
        }
        self.table = table
        overrides = language.specs ?? [:]
    }

    /// `Role:label`, `Role:~part` and `Outer>Inner`, with the labels translated.
    func spec(_ spec: String) -> String {
        spec.components(separatedBy: ">").map { part in
            let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
            return pieces.count == 2 ? "\(pieces[0]):\(label(pieces[1]))" : part
        }.joined(separator: ">")
    }

    /// A window's title, or a spec for one that has none.
    func window(_ title: String) -> String { title.hasPrefix("AX") ? spec(title) : label(title) }

    func label(_ english: String) -> String {
        if let own = overrides[english] { return own }
        let part = english.hasPrefix("~")
        let text = part ? String(english.dropFirst()) : english
        if let translated = table[text] { return (part ? "~" : "") + translated }
        // A separator or a number is the same in every language; a name may
        // be too (`kevinabouhanna`), which the report lets you tell.
        if text.rangeOfCharacter(from: .letters) != nil { missing.insert(english) }
        return english
    }
}

/// An image, GIF or video the pages use that isn't a shot's picture (NetworkMonitor#413).
/// Every asset a page uses must be either a shot's `file` or one of these, so
/// none can go stale unnoticed: `coverage` fails on any that isn't.
struct HandMade: Decodable {
    var file: String
    /// The shots whose windows it shows. When one changes, it's named for
    /// remaking by hand until that shot is updated by name.
    var shows: [String]?
    /// Or why it shows no window this tool can check: an icon, the menu bar.
    var none: String?
    /// Or, in the README's list, the shot whose picture it's a copy of (NetworkMonitor#434):
    /// `update` copies the site's picture here, and each language's to
    /// `<folder>/<code>/<name>`, which needn't be listed.
    var copy: String?
    /// With `shows`, required: the app version it was made from, such as
    /// `1.28.1` (NetworkMonitor#421). It fails the check when it's older than the record of
    /// a window it shows (`Versions`), so an asset that was out of date on the
    /// day it was listed doesn't pass.
    var made: String?
    /// The issue its remake waits on, such as `NetworkMonitor#458`, when it's out of date
    /// and can't be remade yet: the check names it without failing. It fails
    /// again once the asset is as new as its windows, until this comes out.
    var stale: String?
}

/// The app version each window's record was taken from (NetworkMonitor#421), in
/// `shots/trees/versions.json`, by file name: `{"popover.txt": "1.28.1",
/// "popover.made.txt": "1.28.1"}`. English only, as what's made by hand is.
/// `update` keeps a record's version while the tree it holds stays the same,
/// since the window looked the same then, and sets this run's app version
/// when it changes.
enum Versions {
    static let file = "versions.json"

    static func read(_ trees: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: trees.appendingPathComponent(file)),
              let versions = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return versions
    }

    static func write(_ versions: [String: String], to trees: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(versions) + Data("\n".utf8)).write(to: trees.appendingPathComponent(file))
    }

    /// The version of the app at `path`, from its Info.plist.
    static func app(_ path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String)
    }

    /// `1.26.7`, `1.28`: numbers and dots only.
    static func valid(_ version: String) -> Bool {
        version.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
    }

    /// Whether `a` is an earlier version than `b`: 1.9 is before 1.10.
    static func older(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }
}

/// The README's and the docs' assets, in `Resources/README/assets.json` on
/// `main`, listed the same way.
struct RepoAssets: Decodable {
    var assets: [HandMade]
}

/// Where the repo's list lives, relative to its checkout.
var repoAssetsPath: String { config.repoAssets }

/// A language's copy of one of the README's pictures: `Resources/README/<code>/speed-test.png`.
func repoFile(_ english: String, in language: Language?) -> String {
    guard let language else { return english }
    let url = URL(fileURLWithPath: english)
    let folder = url.deletingLastPathComponent().relativePath
    return (folder == "." ? "" : folder + "/") + language.code + "/" + url.lastPathComponent
}

/// Copies into the README each site picture it uses, in `language` (NetworkMonitor#434), so
/// the README's pictures in every language come from the run that takes the
/// site's: those of the shots in `shots`, or all of them. Only those a page
/// uses, or that are there already, so a language without a README gets none.
/// Returns what it copied.
func copyToRepo(manifest: Manifest, site: URL, repo: URL, repoAssets: RepoAssets?, language: Language?,
                shots: Set<String>? = nil) throws -> [String] {
    let uses = try Coverage.repoUses(repo)
    var copied: [String] = []
    for asset in repoAssets?.assets ?? [] {
        guard let name = asset.copy, shots?.contains(name) ?? true else { continue }
        guard let english = manifest.shots.first(where: { $0.name == name })?.file else {
            throw Failure("\(asset.file) is a copy of \"\(name)\", which isn't a shot with a picture")
        }
        let from = site.appendingPathComponent(language.map { $0.file(english) } ?? english)
        let file = repoFile(asset.file, in: language)
        let to = repo.appendingPathComponent(file)
        guard uses[file] != nil || FileManager.default.fileExists(atPath: to.path),
              let picture = try? Data(contentsOf: from), (try? Data(contentsOf: to)) != picture else { continue }
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try picture.write(to: to)
        copied.append(file)
    }
    return copied
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
    /// manifest's `assets` say with `shows`. With nowhere to say which version
    /// each was made from (`made`, NetworkMonitor#421), an entry here fails the check: list
    /// it under `assets` instead.
    var flags: [String]?
    /// The file the manifest's `render` writes for it (product-kit#8).
    var render: String?

    /// The same shot in `language`: the app opened in it, its elements named
    /// in it, its picture in the language's folder. Videos and staged pictures
    /// are the English shot's business.
    func localized(_ language: Language, _ t: Translator) -> Shot {
        var shot = self
        // AppleLanguages too, so dates and times come out as that language
        // writes them, as on a Mac set to it.
        shot.open = open + config.language.map { $0.replacingOccurrences(of: "{code}", with: language.code) }
        shot.window = t.window(window)
        shot.file = file.map(language.file)
        shot.click = click?.map(t.spec)
        shot.scroll = scroll.map(t.spec)
        shot.waitFor = waitFor.map { Wait(element: t.spec($0.element), seconds: $0.seconds) }
        shot.skipIf = skipIf.map(t.spec)
        shot.ignore = ignore?.map(t.spec)
        shot.data = data?.map { region in
            var region = region
            region.from = t.spec(region.from)
            region.until = region.until.map { ["end", "run"].contains($0) ? $0 : t.spec($0) }
            return region
        }
        shot.crop = crop.map { c in
            var c = c
            c.from = t.spec(c.from); c.through = t.spec(c.through)
            return c
        }
        shot.areas = areas?.map { a in
            var a = a
            a.element = t.spec(a.element)
            return a
        }
        shot.flags = nil
        return shot
    }
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
    /// Lines that come and go with the Mac's state, such as Network's status
    /// lines on a hotspot (NetworkMonitor#416): the region may be empty, and only that it's
    /// there is kept, not its roles.
    var optional: Bool?
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
    // Chinese times and days (NetworkMonitor#431): 早上5:51, 下午#, 星期一, 周一.
    s = s.replacingOccurrences(of: "(凌晨|早上|上午|中午|下午|晚上)\\s?#", with: "‹time›", options: .regularExpression)
    s = s.replacingOccurrences(of: "(星期|周)[一二三四五六日天]", with: "‹day›", options: .regularExpression)
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
        // The menu bar readout keeps its width, rates and all: it's drawn at
        // one width in either unit, so a change in it is the readout's (NetworkMonitor#424).
        let keepsWidth = r == "AXMenuBarItem"
        parts.append(!keepsWidth && (r == "AXStaticText" || hasNumber || containerRoles.contains(r))
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

/// `masked` is told of each element whose looks the tree doesn't keep: data,
/// what's left out, a number or a date, a setting's value. The look check
/// leaves them out of the picture too (NetworkMonitor#423).
func tree(_ window: AXUIElement, data: [DataRegion], ignore: [String] = [],
          masked: ((AXUIElement) -> Void)? = nil) -> [String] {
    var out: [String] = []
    /// Whether the element's subtree held a data region.
    @discardableResult
    func walk(_ element: AXUIElement, _ depth: Int) -> Bool {
        let pad = String(repeating: "  ", count: depth)
        let index = out.count
        out.append(pad + line(element))
        if let masked, depth > 0, showsData(element) { masked(element) }
        let kids = children(element).filter { kid in
            let kept = !ignoredRoles.contains(role(kid)) && !ignore.contains { matches(kid, $0) }
            if !kept { masked?(kid) }
            return kept
        }
        var holdsData = false
        var i = 0
        while i < kids.count {
            if let region = data.first(where: { matches(kids[i], $0.from) }) {
                if let skip = region.skip, skip > 0 {
                    // The label itself stays interface.
                    for k in i..<min(i + skip, kids.count) { if walk(kids[k], depth + 1) { holdsData = true } }
                    i += skip
                    guard i < kids.count else {
                        if region.optional == true { out.append(pad + "  data: optional"); holdsData = true }
                        break
                    }
                }
                var end = i + 1
                if let until = region.until {
                    switch until {
                    case "end": end = kids.count
                    case "run": while end < kids.count && role(kids[end]) == role(kids[i]) { end += 1 }
                    default:    end = kids[(i + 1)...].firstIndex { matches($0, until) } ?? kids.count
                    }
                }
                if let masked { kids[i..<end].forEach(masked) }
                out.append(pad + "  data: " + (region.optional == true ? "optional"
                                               : roles(in: Array(kids[i..<end])).joined(separator: " ")))
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

/// Whether an element shows what the tree masks in its labels: a number, a
/// date, a setting's value. A container's labels say nothing of its looks.
func showsData(_ element: AXUIElement) -> Bool {
    let r = role(element)
    if containerRoles.contains(r) { return false }
    // A text area is the user's in Settings, but About's credits too: by
    // what it shows, as text is.
    if settingRoles.contains(r), r != "AXTextArea", text(element, kAXValueAttribute) != nil { return true }
    return labels(element).contains { mask($0) != $0.replacingOccurrences(of: "\n", with: " ") }
}

// MARK: - The look (NetworkMonitor#423)

/// What a window looks like, for what its tree can't tell: a colour, an icon,
/// spacing, a font. A small thumbnail of its picture, its average colour in
/// each cell of a grid `Look.across` cells along its longer side, five bits a
/// channel, kept as `shots/trees/<name>.look`. Cells over anything the tree
/// masks (data, a number, a setting's value, a line it leaves out) are left
/// out, `----`.
struct Look {
    /// The picture's size in pixels, and the grid's in cells.
    var width: Int, height: Int, columns: Int, rows: Int
    /// Each cell's colour, five bits a channel, red highest; nil where masked.
    var cells: [UInt16?]

    static let across = 128

    /// `masks` in the picture's pixels, from its top left.
    init?(_ image: CGImage, masks: [CGRect]) {
        let width = image.width, height = image.height
        let cell = max(1, Int((Double(max(width, height)) / Double(Look.across)).rounded(.up)))
        let columns = (width + cell - 1) / cell, rows = (height + cell - 1) / cell
        (self.width, self.height, self.columns, self.rows) = (width, height, columns, rows)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var cells: [UInt16?] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let r = CGRect(x: column * cell, y: row * cell, width: cell, height: cell).intersection(bounds)
                if masks.contains(where: { $0.intersects(r) }) { cells.append(nil); continue }
                var sum = (0, 0, 0), n = 0
                // The buffer's rows run from the top, as the picture's do.
                for y in Int(r.minY)..<Int(r.maxY) {
                    for x in Int(r.minX)..<Int(r.maxX) {
                        let i = y * bytesPerRow + x * 4
                        sum.0 += Int(pixels[i]); sum.1 += Int(pixels[i + 1]); sum.2 += Int(pixels[i + 2]); n += 1
                    }
                }
                let level = { (v: Int) in UInt16((Double(v) / Double(max(n, 1)) / 255 * 31).rounded()) }
                cells.append(level(sum.0) << 10 | level(sum.1) << 5 | level(sum.2))
            }
        }
        self.cells = cells
    }

    init?(text: String) {
        var lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return nil }
        let head = lines.removeFirst().split(separator: " ").compactMap { Int($0) }
        guard head.count == 4 else { return nil }
        (width, height, columns, rows) = (head[0], head[1], head[2], head[3])
        // Four hex digits a cell, a row a line.
        cells = lines.flatMap { line in
            stride(from: 0, to: line.count, by: 4).map { i -> UInt16? in
                let start = line.index(line.startIndex, offsetBy: i)
                return UInt16(line[start..<line.index(start, offsetBy: 4)], radix: 16)
            }
        }
        guard cells.count == columns * rows else { return nil }
    }

    var text: String {
        "\(width) \(height) \(columns) \(rows)\n" + (0..<rows).map { row in
            cells[(row * columns)..<((row + 1) * columns)]
                .map { $0.map { String(format: "%04x", $0) } ?? "----" }.joined()
        }.joined(separator: "\n") + "\n"
    }

    /// A cell differs when a channel is off by more than this many levels of
    /// 32: one level is a colour on a level's edge (NetworkMonitor#423).
    static let tolerance = 1

    /// How many cells may differ before the window is named. On real
    /// captures hours apart none did; an 8-point icon in another colour
    /// changes 2, a 16-point one 6, a line moved by 2 points over a hundred
    /// (product-kit docs/shots-kit.md).
    static let threshold = 1

    /// The cells, masked in neither, whose colour differs; nil when the
    /// pictures aren't the same size.
    func differing(from other: Look) -> (count: Int, of: Int)? {
        guard width == other.width, height == other.height, cells.count == other.cells.count else { return nil }
        var count = 0, of = 0
        for (a, b) in zip(cells, other.cells) {
            guard let a, let b else { continue }
            of += 1
            let channels = [(a >> 10, b >> 10), ((a >> 5) & 31, (b >> 5) & 31), (a & 31, b & 31)]
            if channels.contains(where: { abs(Int($0.0) - Int($0.1)) > Look.tolerance }) { count += 1 }
        }
        return (count, of)
    }
}

/// Whether `check` compares looks too (`--look`): it needs the windows in
/// front, so it's asked for; `update` always does.
nonisolated(unsafe) var compareLooks = false

/// How long a run may wait, silently, for the Mac to be left idle or locked
/// before it takes what needs the real screen (`--wait-away MINUTES`, NetworkMonitor#521).
/// None by default: those shots are reported as not taken.
nonisolated(unsafe) var waitAway: Double = 0

/// What the tree masks in `window`, in screen points: each element's frame.
func maskedFrames(_ window: AXUIElement, _ shot: Shot) -> [CGRect] {
    var frames: [CGRect] = []
    _ = tree(window, data: shot.data ?? [], ignore: shot.ignore ?? []) { element in
        if let f = frame(element) { frames.append(f) }
    }
    return frames
}

// MARK: - The screens

/// The screen every window is read and taken on (NetworkMonitor#487): the built-in Retina
/// display, or another Retina one; nil without one. The pictures are 2x, so
/// it's a Retina screen; it's the same whichever screen is the main one.
func stage() -> NSScreen? {
    let retina = NSScreen.screens.filter { $0.backingScaleFactor >= 2 }
    let builtIn = retina.first { screen in
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDisplayIsBuiltin($0.uint32Value) != 0 } ?? false
    }
    return builtIn ?? retina.first
}

/// Where the app keeps its windows (`NSWindow Frame Main`): a run moves them
/// onto the stage, and puts them back once the app has quit, so the
/// person's window opens where they left it.
struct SavedFrames {
    let bundle: CFString
    let frames: [String: CFPropertyList]

    init(bundle: String) {
        self.bundle = bundle as CFString
        CFPreferencesAppSynchronize(self.bundle)
        let keys = CFPreferencesCopyKeyList(self.bundle, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        var frames: [String: CFPropertyList] = [:]
        for key in keys where key.hasPrefix("NSWindow Frame ") {
            frames[key] = CFPreferencesCopyAppValue(key as CFString, self.bundle)
        }
        self.frames = frames
    }

    /// Only once the app has quit, or it would write its own over them.
    func restore() {
        CFPreferencesAppSynchronize(bundle)
        let now = CFPreferencesCopyKeyList(bundle, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        for key in Set(now.filter { $0.hasPrefix("NSWindow Frame ") }).union(frames.keys) {
            CFPreferencesSetAppValue(key as CFString, frames[key], bundle)
        }
        CFPreferencesAppSynchronize(bundle)
    }
}

/// Kept for the run: each puts the app back on a signal.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

/// When this run last clicked with the real pointer: that click counts as input.
nonisolated(unsafe) var lastOwnInput: Date?

/// Seconds since anyone used the keyboard or mouse; infinite while the screen is locked.
func secondsIdle() -> Double {
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
       session["CGSSessionScreenIsLocked"] as? Bool == true { return .infinity }
    let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    // No input since this run's own click, which it made only while the Mac was idle.
    if let last = lastOwnInput, idle >= Date().timeIntervalSince(last) - 1 { return .infinity }
    return idle
}

/// How long the Mac has to have been left alone before a run takes focus or
/// moves the pointer (NetworkMonitor#475): MAC_LANE_IDLE seconds (90) with no keyboard or
/// mouse, or the screen locked. MAC_LANE_IDLE=0 takes them whenever.
let awayAfter = Double(ProcessInfo.processInfo.environment["MAC_LANE_IDLE"] ?? "") ?? 90

func isAway() -> Bool { awayAfter <= 0 || secondsIdle() >= awayAfter }

/// A shot that needs a window brought forward or a real click while someone
/// is at the Mac. It isn't waited for there, with the lanes held (NetworkMonitor#504): the run
/// reads every other window first, lets the lanes go, waits until the Mac is idle, and takes them again for these.
struct NeedsAway: Error { let what: String }

/// Before taking focus or moving the pointer.
func needAway(_ what: String) throws {
    if !isAway() { throw NeedsAway(what: what) }
}

// MARK: - Launching

/// Runs a tool to its end: its exit status, and what it printed.
@discardableResult
func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    guard (try? p.run()) != nil else { return (-1, "couldn't run \(path)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The app's launch jobs in launchd (`application.<bundle>.<n>.<n>`), with
/// each one's process, or nil for a job left with none (NetworkMonitor#508).
func launchJobs(_ bundle: String) -> [(label: String, pid: Int32?)] {
    runTool("/bin/launchctl", ["list"]).output.split(separator: "\n").compactMap { line in
        let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
        guard f.count >= 3, f[2].hasPrefix("application.\(bundle).") else { return nil }
        return (String(f[2]), Int32(f[0]))
    }
}

/// Opens the app in the background (-g). Started straight after a quit, while
/// launchd still has the last launch's job, `open` fails with launchd's error
/// 37, "Operation already in progress" (NetworkMonitor#508): then it removes that job, the
/// one with no process, and tries once more, saying so.
func openApp(_ path: String, bundle: String, _ arguments: [String], until started: () -> Bool) throws {
    var removed = false, last = ""
    for attempt in 1...4 {
        let open = runTool("/usr/bin/open", ["-g", "-a", path] + (arguments.isEmpty ? [] : ["--args"] + arguments))
        if open.status == 0 {
            for _ in 0..<40 where !started() { usleep(250_000) }
            if started() { return }
        }
        last = open.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if open.output.contains("Code=37"), !removed {
            removed = true
            let dead = launchJobs(bundle).filter { $0.pid == nil }
            for job in dead {
                let r = runTool("/bin/launchctl", ["remove", job.label])
                print("  launchd still had \(job.label) from the last launch, with no process: "
                      + (r.status == 0 ? "removed it" : "couldn't remove it (\(r.output.trimmingCharacters(in: .whitespacesAndNewlines)))"))
            }
            print("  opening \(path) again")
            continue
        }
        if attempt >= 3 { break }
        sleep(2)
    }
    throw Failure("\(path) didn't start" + (last.isEmpty ? "" : ": \(last)"))
}

// MARK: - The Mac lanes

/// The Mac as a run uses it (NetworkMonitor#504, NetworkMonitor#506). The app's lane and `screen`
/// lanes are held only while it reads or takes windows, never while it waits
/// for the Mac to be idle (NetworkMonitor#521). Letting them go puts the app back: every copy quit,
/// its windows' frames back where they were, and the installed copy
/// running again if it was when they were taken, whichever copy the run used
/// (`--app`).
final class Mac: @unchecked Sendable {
    let manifest: Manifest
    let installed: Manifest
    let command: String
    private var lanes: Process?
    private var lanesInput: Pipe?
    private var lanesHeld = false
    private var savedFrames: SavedFrames?
    private var installedWasRunning = false
    private let lock = NSLock()

    init(manifest: Manifest, installed: Manifest, command: String) {
        self.manifest = manifest; self.installed = installed; self.command = command
    }

    var holding: Bool { lock.withLock { savedFrames != nil } }

    /// Lanes a caller holds already (`mac-lane build/site-shots …`) stay held
    /// until it's done, waits included.
    var callerHolds: Bool {
        let held = (ProcessInfo.processInfo.environment["MAC_LANE_HELD"] ?? "").split(separator: " ").map(String.init)
        return held.contains(lane) && held.contains("screen")
    }

    /// The app's lane: the config's, or its bundle id's last part, lowercased.
    var lane: String {
        config.lane ?? (manifest.bundle.split(separator: ".").last.map { $0.lowercased() } ?? "app")
    }

    /// Takes both lanes, waiting for whoever holds them, and notes how the app is.
    func hold(_ what: String) throws {
        guard !holding else { return }
        if !callerHolds { try takeLanes(what) }
        lock.withLock {
            let path = URL(fileURLWithPath: installed.app).resolvingSymlinksInPath().path
            installedWasRunning = NSRunningApplication.runningApplications(withBundleIdentifier: installed.bundle)
                .contains { $0.bundleURL?.resolvingSymlinksInPath().path == path }
            savedFrames = SavedFrames(bundle: manifest.bundle)
        }
    }

    /// Puts the app back as it was, then lets the lanes go.
    func letGo() {
        let (frames, reopen): (SavedFrames?, Bool) = lock.withLock {
            defer { savedFrames = nil }
            return (savedFrames, installedWasRunning)
        }
        guard let frames else { return }
        Session(manifest: manifest).quit()
        // Its windows back where they were, once it has quit (NetworkMonitor#487).
        frames.restore()
        if reopen {
            do {
                let app = installed
                try openApp(app.app, bundle: app.bundle, []) {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundle).isEmpty
                }
            } catch { print("shots-kit: couldn't open the installed app again: \(error)") }
        }
        releaseLanes()
    }

    /// Waits silently, with the lanes free, until the Mac happens to be idle
    /// (NetworkMonitor#521): nobody is ever told or asked to step away. Then takes them for what
    /// needs him away; again if he came back while they were busy. Gives up at
    /// `deadline`, returning false, with the lanes free.
    func holdOnceAway(_ what: String, until deadline: Date) throws -> Bool {
        if callerHolds { print("  (the lanes stay held meanwhile: the command that ran this holds them)") }
        while true {
            while !isAway() {
                if Date() >= deadline { return false }
                sleep(5)
            }
            try hold(what)
            if isAway() { return true }
            // Back while the lanes were busy: let them go again, the app untouched.
            lock.withLock { savedFrames = nil }
            releaseLanes()
        }
    }

    /// Both lanes, held by a `mac-lane` that runs until this run closes its
    /// input, or ends: the lanes go with it however it ends.
    private func takeLanes(_ what: String) throws {
        // The project's fallback copy, where it has one; the shared one otherwise.
        let repoCopy = repoRoot.appendingPathComponent("Scripts/mac-lane.sh").standardizedFileURL.path
        let macLane = FileManager.default.isExecutableFile(atPath: repoCopy) ? repoCopy : "mac-lane"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["MAC_LANE=\(lane)", "MAC_LANE_WHAT=shots-kit \(command): \(what)", macLane,
                       "env", "MAC_LANE=screen", macLane, "/bin/sh", "-c", "echo held; exec cat >/dev/null"]
        var env = ProcessInfo.processInfo.environment
        env["MAC_LANE_IDLE"] = nil   // this run waits for the Mac to be idle itself, with the lanes free
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        lock.withLock { lanes = p; lanesInput = input; lanesHeld = false }
        var said = Data()
        while !String(decoding: said, as: UTF8.self).contains("held") {
            let more = output.fileHandleForReading.availableData
            if more.isEmpty { break }
            said += more
        }
        guard String(decoding: said, as: UTF8.self).contains("held") else {
            p.waitUntilExit()
            lock.withLock { lanes = nil; lanesInput = nil }
            throw Failure("couldn't take the \(lane) and screen Mac lanes (mac-lane exited \(p.terminationStatus))")
        }
        lock.withLock { lanesHeld = true }
    }

    private func releaseLanes() {
        let (p, input, held): (Process?, Pipe?, Bool) = lock.withLock {
            defer { lanes = nil; lanesInput = nil }
            return (lanes, lanesInput, lanesHeld)
        }
        try? input?.fileHandleForWriting.close()
        // Still waiting for them: it ignores the signals this run does.
        if let p, !held, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p?.waitUntilExit()
    }

    /// However the run ends: the app put back, the lanes let go, a wait for
    /// them given up.
    func end() {
        letGo()
        releaseLanes()
    }
}

// MARK: - The app

struct Session {
    let manifest: Manifest
    /// Opens windows behind the others without activating the app (the
    /// config's `launch.background`, NetworkMonitor#475), for commands that only read the tree.
    var background = false

    var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: manifest.bundle).first
    }

    /// Quits every copy, the installed one and a development build alike: they
    /// share settings. Gracefully, then waits until launchd has let go of each
    /// one's launch job, or opening it again can fail (NetworkMonitor#508).
    func quit() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: manifest.bundle)
        guard !apps.isEmpty else { return }
        apps.forEach { $0.terminate() }
        for _ in 0..<80 where apps.contains(where: { !$0.isTerminated }) { usleep(250_000) }
        for app in apps where !app.isTerminated { app.forceTerminate(); usleep(500_000) }
        for _ in 0..<60 where !launchJobs(manifest.bundle).isEmpty { usleep(250_000) }
        usleep(500_000)
    }

    func launch(_ arguments: [String]) throws {
        quit()
        // -g: never brings the app forward by itself (NetworkMonitor#475).
        try openApp(manifest.app, bundle: manifest.bundle, arguments + (background ? config.background : [])) { running != nil }
    }

    func window(_ title: String) throws -> AXUIElement {
        guard let app = running else { throw Failure("the app isn't running") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<60 {
            var windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
            // The menu bar readout isn't in a window: it's the app's status
            // item, `AXMenuBarItem` in its extras menu bar (NetworkMonitor#424).
            if let extras = attribute(ax, kAXExtrasMenuBarAttribute) { windows.append(extras as! AXUIElement) }
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

    func bringForward(_ window: AXUIElement) throws {
        try needAway("its window brought forward")
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
        try needAway("a click")
        for _ in 0..<4 {
            try bringForward(window)
            let point = CGPoint(x: f.minX + min(40, f.width / 2), y: f.midY)
            let saved = CGEvent(source: nil)?.location
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(60_000)
            }
            lastOwnInput = Date()
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
        // What it showed instead, to tell a slow window from a wrong spec.
        let showing = tree(window, data: []).prefix(30).joined(separator: "\n")
        throw Failure("\(wait.element) didn't appear within \(Int(wait.seconds)) s; the window showed:\n\(showing)")
    }

    /// Puts a window in one place before it's read or taken (NetworkMonitor#487): on the
    /// stage screen, `stage()`, 60 points from its visible frame's left and 40
    /// from its top. A window lays out to whole points on a 1x screen and to
    /// half points on a Retina one, so a toolbar segment 37.5 points wide on
    /// one is 38 on the other and rounds to another size; and a translucent
    /// sidebar shows what's behind it. Where the window last was, or which
    /// screen is the main one, changes neither. A popover and the menu bar
    /// readout stay where they are: the popover opens on the Retina screen
    /// itself (`-popoverScreen retina`).
    func place(_ window: AXUIElement) {
        guard role(window) == "AXWindow", let f = frame(window), let screen = stage() else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // In screen points from the top left, as accessibility has them.
        let visible = CGRect(x: screen.visibleFrame.minX, y: primaryHeight - screen.visibleFrame.maxY,
                             width: screen.visibleFrame.width, height: screen.visibleFrame.height)
        var to = CGPoint(x: visible.minX + max(0, min(60, visible.width - f.width)),
                         y: visible.minY + max(0, min(40, visible.height - f.height)))
        guard f.origin != to, let value = AXValueCreate(.cgPoint, &to) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        // It lays out again for the new screen's scale.
        usleep(800_000)
    }

    func capture(_ window: AXUIElement, crop: Crop?) async throws -> CGImage {
        try await picture(window, crop: crop).image
    }

    /// A capture, with where its top left is on screen and its points to
    /// pixels: to place the masks of the look check on it (NetworkMonitor#423).
    func picture(_ window: AXUIElement, crop: Crop?) async throws -> (image: CGImage, origin: CGPoint, scale: CGFloat) {
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
        guard let crop else { return (image, target.frame.origin, 2) }
        let r = try crop.rect(in: window)
        let rect = CGRect(x: (r.minX * 2).rounded(), y: (r.minY * 2).rounded(), width: (r.width * 2).rounded(), height: (r.height * 2).rounded())
        guard let cropped = image.cropping(to: rect) else { throw Failure("crop is outside the window") }
        return (cropped, CGPoint(x: target.frame.minX + r.minX, y: target.frame.minY + r.minY), 2)
    }

    /// The window as it looks now, active, with the tree's masks laid on it.
    func look(_ window: AXUIElement, _ shot: Shot) async throws -> (look: Look, picture: CGImage, masks: [CGRect]) {
        place(window)
        var picture = try await picture(window, crop: shot.crop)
        for _ in 0..<4 where shot.crop == nil && !isActive(picture.image, window: window) {
            try bringForward(window)
            picture = try await self.picture(window, crop: shot.crop)
        }
        let masks = maskedFrames(window, shot).map { f in
            CGRect(x: (f.minX - picture.origin.x) * picture.scale, y: (f.minY - picture.origin.y) * picture.scale,
                   width: f.width * picture.scale, height: f.height * picture.scale)
        }
        guard let look = Look(picture.image, masks: masks) else { throw Failure("can't read the capture's colours") }
        return (look, picture.image, masks)
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
    // A language's first pictures go in folders that don't exist yet.
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw Failure("can't write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("can't write \(url.path)") }
}

// MARK: - The page

struct Page {
    let url: URL
    var html: String
    /// From the page's folder back to the site's root, before each asset's
    /// path in its links: `../` for a language's page in a folder.
    let up: String

    init(site: URL, path: String = "index.html", up: String = "") throws {
        url = site.appendingPathComponent(path)
        html = try String(contentsOf: url, encoding: .utf8)
        self.up = up
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
        editAll(tagsContaining: "\"\(up)\(file)") { tag in
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
/// checked against the lists (NetworkMonitor#413). Reads files only: no app, no
/// Accessibility, so it runs in CI.
enum Coverage {
    static let media = "png|jpe?g|gif|webp|svg|mp4|webm|mov"

    /// The site's files a browser reads for media (NetworkMonitor#425): its pages, at the
    /// top and in folders (each language's, zh/index.html, NetworkMonitor#430), their
    /// stylesheets and their scripts. Not the folders that aren't the site:
    /// hidden ones (.github), shots/ (this tool's), and another checkout
    /// inside it (the app's, which the site's workflow puts in app/).
    static func siteFiles(_ site: URL) -> [String] {
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: site.path) else { return [] }
        var files: [String] = []
        while let path = walk.nextObject() as? String {
            let name = (path as NSString).lastPathComponent
            if walk.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                if name.hasPrefix(".") || path == "shots"
                    || fm.fileExists(atPath: site.appendingPathComponent(path).appendingPathComponent(".git").path) {
                    walk.skipDescendants()
                }
            } else if !name.hasPrefix("."),
                      ["html", "htm", "css", "js", "mjs"].contains((name as NSString).pathExtension.lowercased()) {
                files.append(path)
            }
        }
        return files.sorted()
    }

    /// The site's own assets: `assets/…`, as a relative link or on the site's
    /// own address (the social preview's `<meta>` tags), wherever it's
    /// written: an attribute, a `srcset`'s list, a stylesheet's `url(…)`, a
    /// string in a script that adds it. Another site's `/assets/` isn't ours.
    static func siteUses(_ site: URL) throws -> [String: Set<String>] {
        // The site's own address, without its scheme: `example.github.io/App/`.
        let own = config.siteURL.map { url -> String in
            let bare = url.replacingOccurrences(of: #"^[a-z]+://"#, with: "", options: .regularExpression)
            return "|" + NSRegularExpression.escapedPattern(for: bare.hasSuffix("/") ? bare : bare + "/")
        } ?? ""
        let regex = try NSRegularExpression(
            pattern: #"(?:^|["'`(=,\s]"# + own + #")(?:\.\./)*(assets/[A-Za-z0-9_./@-]+\.(?:"# + media + #"))"#,
            options: [.caseInsensitive, .anchorsMatchLines])
        var uses: [String: Set<String>] = [:]
        // A page in a folder climbs out with ../; a script's paths are the
        // page's that runs it, so each is the site's assets/ either way.
        for file in siteFiles(site) {
            guard let text = try? String(contentsOf: site.appendingPathComponent(file), encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                uses[ns.substring(with: m.range(at: 1)), default: []].insert(file)
            }
        }
        return uses
    }

    /// The README's, SECURITY's and the docs' Markdown pages: README.<code>.md
    /// for each language (NetworkMonitor#430), and every page under docs/, however deep
    /// (docs/<code>/, the design log's docs/design-overhaul, NetworkMonitor#437).
    static func repoPages(_ repo: URL) -> [String] {
        let fm = FileManager.default
        var pages = ["README.md", "SECURITY.md"]
        let files = (try? fm.contentsOfDirectory(atPath: repo.path)) ?? []
        pages += files.filter { $0.hasPrefix("README.") && $0.hasSuffix(".md") && $0 != "README.md" }.sorted()
        var docs: [String] = []
        if let walk = fm.enumerator(atPath: repo.appendingPathComponent("docs").path) {
            while let path = walk.nextObject() as? String {
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix(".") {
                    walk.skipDescendants()
                } else if name.lowercased().hasSuffix(".md") {
                    docs.append("docs/" + path)
                }
            }
        }
        return pages + docs.sorted()
    }

    /// A Markdown page with its code blanked out, fenced and inline, which
    /// GitHub shows as text: an example there isn't a picture on the page.
    static func withoutCode(_ text: String) -> String {
        var fence: String?
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            // At any depth: a list item's code is indented with it.
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let marker = String(trimmed.prefix { $0 == "`" || $0 == "~" })
            if let open = fence {
                if marker.first == open.first, marker.count >= open.count,
                   trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                lines.append("")
            } else if marker.count >= 3, Set(marker).count == 1,
                      marker.first == "~" || !trimmed.dropFirst(marker.count).contains("`") {
                fence = marker
                lines.append("")
            } else {
                lines.append(line)
            }
        }
        let inline = try! NSRegularExpression(pattern: "(`+).*?\\1")
        let joined = lines.joined(separator: "\n")
        return inline.stringByReplacingMatches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length),
                                               withTemplate: "")
    }

    /// The links to pictures in one Markdown page, as written: HTML's `src`,
    /// `poster` and `srcset` (a `<picture>`'s `<source>` too), and Markdown's
    /// images, inline `![alt](path)` or by reference, `![alt][ref]`,
    /// `![ref][]` or `![ref]`, with `[ref]: path` anywhere on the page.
    static func pictureLinks(_ markdown: String) throws -> [String] {
        let text = withoutCode(markdown)
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        var links: [String] = []
        let html = try NSRegularExpression(pattern: #"\b(src|poster|srcset)\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive)
        for m in html.matches(in: text, range: all) {
            guard let attribute = group(m, 1), let value = group(m, 2) else { continue }
            if attribute.lowercased() == "srcset" {
                // `a.png 1x, a@2x.png 2x`: each candidate's address.
                links += value.components(separatedBy: ",").compactMap {
                    $0.split(whereSeparator: \.isWhitespace).first.map(String.init)
                }
            } else {
                links.append(value)
            }
        }
        let inline = try NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*<?([^)\s>]+)"#)
        links += inline.matches(in: text, range: all).compactMap { group($0, 1) }
        // References: labels match without regard to case or spacing, and
        // the first definition of one wins.
        func label(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var definitions: [String: String] = [:]
        let definition = try NSRegularExpression(pattern: #"^ {0,3}\[([^\]]+)\]:[ \t]*<?([^\s>]+)>?"#, options: .anchorsMatchLines)
        for m in definition.matches(in: text, range: all) {
            guard let name = group(m, 1), let link = group(m, 2), definitions[label(name)] == nil else { continue }
            definitions[label(name)] = link
        }
        let reference = try NSRegularExpression(pattern: #"!\[([^\]]*)\](?:\[([^\]]*)\])?(?![(\[])"#)
        for m in reference.matches(in: text, range: all) {
            let ref = group(m, 2).flatMap { $0.isEmpty ? nil : $0 } ?? group(m, 1) ?? ""
            if let link = definitions[label(ref)] { links.append(link) }
        }
        return links
    }

    /// The README's, SECURITY's and the docs' local media, as paths from the
    /// checkout's root.
    static func repoUses(_ repo: URL) throws -> [String: Set<String>] {
        let mediaRegex = try NSRegularExpression(pattern: #"\.(?:"# + media + #")$"#, options: .caseInsensitive)
        let root = repo.standardizedFileURL.path + "/"
        var uses: [String: Set<String>] = [:]
        for page in repoPages(repo) {
            guard let text = try? String(contentsOf: repo.appendingPathComponent(page), encoding: .utf8) else { continue }
            for written in try pictureLinks(text) {
                if written.contains("://") || written.hasPrefix("#") || written.hasPrefix("data:") { continue }
                let link = written.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
                guard mediaRegex.firstMatch(in: link, range: NSRange(location: 0, length: (link as NSString).length)) != nil
                else { continue }
                // Relative to the page, as GitHub reads it.
                let base = repo.appendingPathComponent(page).deletingLastPathComponent()
                let full = URL(fileURLWithPath: link, relativeTo: base).standardizedFileURL.path
                guard full.hasPrefix(root) else { continue }
                uses[String(full.dropFirst(root.count)), default: []].insert(page)
            }
        }
        return uses
    }

    /// What's wrong, one line each; empty when every asset is accounted for.
    /// The site's come first, fixed on `gh-pages`; from `onMain` on, the
    /// README's and the docs', fixed on `main` (NetworkMonitor#426). And what's known to be
    /// out of date, waiting on an issue (`stale`), which doesn't fail it.
    static func problems(manifest: Manifest, site: URL, repoAssets: RepoAssets?, repo: URL?) throws
        -> (problems: [String], onMain: Int, summary: String, stale: [String]) {
        var problems: [String] = [], stale: [String] = []
        let shotNames = Set(manifest.shots.map(\.name))
        // Each window's record, as the version it was taken from (NetworkMonitor#421): the
        // tree what's made by hand was last remade from, or the window's own.
        let trees = site.appendingPathComponent("shots/trees")
        let versions = Versions.read(trees)
        func recorded(_ name: String) -> String? {
            let made = "\(name).made.txt"
            return FileManager.default.fileExists(atPath: trees.appendingPathComponent(made).path) ? versions[made] : versions["\(name).txt"]
        }

        func checkList(_ list: [HandMade], root: URL, listName: String, uses: [String: Set<String>], taken: Set<String>) {
            var seen = Set<String>()
            for asset in list {
                let file = asset.file
                if !seen.insert(file).inserted { problems.append("\(file) is listed twice in \(listName)") }
                if taken.contains(file) { problems.append("\(file) is a shot's picture; take it out of \(listName)'s assets") }
                let shows = asset.shows ?? []
                if asset.copy == nil, shows.isEmpty == (asset.none == nil) {
                    problems.append("\(file) in \(listName) needs either `shows` (the windows it shows) or `none` (why it shows none), not both")
                }
                for name in shows where !shotNames.contains(name) {
                    problems.append("\(file) in \(listName) shows \"\(name)\", which isn't a shot in shots/shots.json"
                                    + (listName == repoAssetsPath ? renamedOnSite : ""))
                }
                // Made from a window older than its record: out of date on
                // the day it was listed, or since a remake of its window (NetworkMonitor#421).
                if !shows.isEmpty, !(asset.made.map(Versions.valid) ?? false) {
                    problems.append("\(file) in \(listName) needs `made`: the app version it was made from, such as \"1.28.1\"")
                } else if !shows.isEmpty, let made = asset.made {
                    let newer = shows.compactMap { name in recorded(name).flatMap { Versions.older(made, than: $0) ? "\(name) (\($0))" : nil } }
                    if newer.isEmpty, let issue = asset.stale {
                        problems.append("\(file) in \(listName) is as new as the windows it shows; take out `stale` (\(issue))")
                    } else if !newer.isEmpty, let issue = asset.stale {
                        stale.append("\(file), made from \(made), waits on \(issue): \(newer.joined(separator: ", ")) changed since")
                    } else if !newer.isEmpty {
                        problems.append("\(file) in \(listName) was made from \(made), but these windows' records are newer: "
                                        + newer.joined(separator: ", ") + ". Remake it and set `made`, or set `stale` to the issue its remake waits on")
                    }
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

        // The site: each asset is a shot's picture, a flag, or listed. Without
        // a site, the README's and the docs' are, against the one list (product-kit#8).
        let inRepo = manifestInRepo && repo != nil
        var siteUses = try siteUses(site)
        if inRepo, let repo { siteUses.merge(try repoUses(repo)) { $0.union($1) } }
        // Each shot's picture, and its copy in each language (NetworkMonitor#431).
        var pictures: [(file: String, shot: String)] = manifest.shots.compactMap { s in s.file.map { ($0, s.name) } }
        var translated: [(file: String, shot: String)] = []
        for language in manifest.languages ?? [] {
            translated += manifest.shots.compactMap { s in s.file.map { (language.file($0), "\(s.name) (\(language.code))") } }
        }
        let shotFiles = Set((pictures + translated).map(\.file))
        // A language's copy is needed once its page shows it: until the first
        // run takes it, the page can show the English one.
        pictures += translated.filter { siteUses[$0.file] != nil }
        for (file, shot) in pictures where !FileManager.default.fileExists(atPath: site.appendingPathComponent(file).path) {
            problems.append("\(file), \(shot)'s picture, doesn't exist")
        }
        let flagged = manifest.shots.flatMap { shot in (shot.flags ?? []).map { HandMade(file: $0, shows: [shot.name]) } }
        checkList((manifest.assets ?? []) + flagged.filter { f in !(manifest.assets ?? []).contains { $0.file == f.file } },
                  root: site, listName: "shots/shots.json", uses: siteUses, taken: shotFiles)
        var summary = inRepo ? "\(siteUses.count) assets in the README and docs" : "\(siteUses.count) assets on the site"

        // The README and the docs.
        let onMain = inRepo ? 0 : problems.count
        if let repo, !inRepo {
            let uses = try repoUses(repo)
            // A copy of a shot's picture is listed once, in English; each
            // language's copy of it comes with it (NetworkMonitor#434).
            var copies = Set<String>()
            for asset in repoAssets?.assets ?? [] {
                guard let name = asset.copy else { continue }
                if manifest.shots.first(where: { $0.name == name })?.file == nil {
                    problems.append("\(asset.file) in \(repoAssetsPath) is a copy of \"\(name)\", which isn't a shot with a picture in shots/shots.json"
                                    + renamedOnSite)
                }
                for language in manifest.languages ?? [] {
                    let file = repoFile(asset.file, in: language)
                    copies.insert(file)
                    if uses[file] != nil, !FileManager.default.fileExists(atPath: repo.appendingPathComponent(file).path) {
                        problems.append("\(file), the \(language.code) copy of \(asset.file), doesn't exist; `update` makes it")
                    }
                }
            }
            checkList(repoAssets?.assets ?? [], root: repo, listName: repoAssetsPath, uses: uses, taken: copies)
            summary += " and \(uses.count) in the README and docs"
        }
        return (problems, onMain, summary, stale)
    }

    /// A shot `main` names, gone from `gh-pages`: the usual cause is a change
    /// there, so say where to follow it (NetworkMonitor#426).
    static var renamedOnSite: String {
        " on \(config.siteBranch). If a change there renamed or removed it, change \(repoAssetsPath) on \(config.repoBranch) to match"
    }

    /// Each branch's problems under its name, so a failure says which branch to
    /// fix. `checking` is the branch the check runs for, from GitHub's
    /// variables; where it's the other one, a note says the problems come from
    /// across the branches (NetworkMonitor#426).
    static func report(_ problems: [String], onMain: Int, checking: String?, head: String?) -> [String] {
        let groups: [(branch: String, what: String, problems: ArraySlice<String>)] = [
            (config.siteBranch, "the site's pages and shots/shots.json", problems[..<onMain]),
            (config.repoBranch, "the README, the docs and \(manifestInRepo ? "shots/shots.json" : repoAssetsPath)", problems[onMain...]),
        ]
        var lines: [String] = []
        for group in groups where !group.problems.isEmpty {
            lines.append("On \(group.branch) (\(group.what)), fixed in a pull request into \(group.branch):")
            if let checking, checking != group.branch {
                let this = head == nil ? "this push" : "this pull request"
                let pair = group.branch == config.siteBranch
                    ? "name that branch \(head ?? "<main's branch>")-site"
                    : "name this branch after that one, with -site"
                lines.append("  Not in \(this)'s files: \(group.branch) changed, or \(this) changes what \(group.branch) has to match. "
                             + "Fix them in a pull request into \(group.branch). To land both at once, \(pair), and each is "
                             + "checked against the other.")
            }
            lines += group.problems.map { "  " + $0 }
        }
        return lines
    }
}

// MARK: - Coverage tests

/// Where the check looks for media, each place a case (NetworkMonitor#425): made-up pages in
/// a folder of their own, scanned like the real ones. `make test` runs them,
/// with `site-shots coverage-test`, so a page that hides a picture from the
/// check can't come back unnoticed.
enum CoverageTests {
    struct Case {
        var name: String
        /// Files, by path, and what's in them.
        var files: [String: String]
        /// What the scan should find: each asset, and the pages using it.
        var expect: [String: Set<String>]
    }

    static let site: [Case] = [
        Case(name: "a page at the top", files: ["index.html": #"<img src="assets/top.png">"#],
             expect: ["assets/top.png": ["index.html"]]),
        Case(name: "a language's page in a folder", files: ["zh/index.html": #"<img src="../assets/zh-Hans/a.png">"#],
             expect: ["assets/zh-Hans/a.png": ["zh/index.html"]]),
        Case(name: "pages deeper in folders, not only index.html",
             files: ["guide/setup/index.html": #"<img src="../../assets/deep.png">"#,
                     "guide/faq.html": #"<video poster="../assets/faq.jpg" src="../assets/faq.mp4">"#],
             expect: ["assets/deep.png": ["guide/setup/index.html"],
                      "assets/faq.jpg": ["guide/faq.html"], "assets/faq.mp4": ["guide/faq.html"]]),
        Case(name: "srcset, and a picture's sources",
             files: ["index.html": """
                 <img srcset="assets/s.png 1x, assets/s@2x.png 2x">
                 <picture><source srcset="assets/p.webp" type="image/webp"><img src="assets/p.png"></picture>
                 """],
             expect: ["assets/s.png": ["index.html"], "assets/s@2x.png": ["index.html"],
                      "assets/p.webp": ["index.html"], "assets/p.png": ["index.html"]]),
        Case(name: "stylesheets, inline and separate",
             files: ["index.html": #"<style>.hero { background: url(assets/inline.png) }</style>"#,
                     "style.css": #".a { background-image: url("assets/top.jpg") }"#,
                     "css/site.css": ".b { background: url('../assets/nested.webp') }"],
             expect: ["assets/inline.png": ["index.html"], "assets/top.jpg": ["style.css"],
                      "assets/nested.webp": ["css/site.css"]]),
        Case(name: "images that scripts add, inline and separate",
             files: ["index.html": "<script>video.poster = 'assets/inline.gif'</script>",
                     "app.js": "img.src = \"assets/script.png\"; el.style.backgroundImage = `url(assets/tick.svg)`",
                     "js/more.mjs": "const clip = `assets/clip.mp4`"],
             expect: ["assets/inline.gif": ["index.html"], "assets/script.png": ["app.js"],
                      "assets/tick.svg": ["app.js"], "assets/clip.mp4": ["js/more.mjs"]]),
        Case(name: "the site's own address, in a social preview",
             files: ["index.html": #"<meta property="og:image" content="https://example.github.io/App/assets/card.png?v=1">"#],
             expect: ["assets/card.png": ["index.html"]]),
        Case(name: "not the site: other sites, this tool's folder, hidden folders, another checkout",
             files: ["index.html": #"<img src="https://example.com/assets/theirs.png"><img src="/assets/root.png">"#,
                     "shots/notes.html": #"<img src="assets/tool.png">"#,
                     ".github/page.html": #"<img src="assets/hidden.png">"#,
                     "app/.git/HEAD": "ref: refs/heads/main",
                     "app/Resources/Social/card.html": #"<img src="assets/app.png">"#],
             expect: [:]),
    ]

    static let repo: [Case] = [
        Case(name: "an inline Markdown image and an <img>",
             files: ["README.md": #"![Demo](Resources/README/demo.gif) <img src="Resources/README/logo.png" width="64">"#],
             expect: ["Resources/README/demo.gif": ["README.md"], "Resources/README/logo.png": ["README.md"]]),
        Case(name: "srcset, and a picture's sources",
             files: ["README.md": """
                 <img srcset="Resources/README/s.png 1x, Resources/README/s@2x.png 2x" src="Resources/README/s.png">
                 <picture>
                   <source media="(prefers-color-scheme: dark)" srcset="Resources/README/dark.png">
                   <img src="Resources/README/light.png">
                 </picture>
                 """],
             expect: ["Resources/README/s.png": ["README.md"], "Resources/README/s@2x.png": ["README.md"],
                      "Resources/README/dark.png": ["README.md"], "Resources/README/light.png": ["README.md"]]),
        Case(name: "reference-style images: full, collapsed and shortcut",
             files: ["README.md": """
                 ![The popover][pop] and ![Speed test][] and ![diagram].
                 A link isn't a picture: [the logo][logo]. Nor is an unused definition.

                 [pop]: Resources/README/popover.png "The popover"
                 [speed TEST]: <Resources/README/speed-test.png>
                 [Diagram]: docs/diagram.svg
                 [logo]: Resources/README/logo.png
                 [unused]: Resources/README/unused.png
                 """],
             expect: ["Resources/README/popover.png": ["README.md"], "Resources/README/speed-test.png": ["README.md"],
                      "docs/diagram.svg": ["README.md"]]),
        Case(name: "the docs' pages in folders, however deep, in every language",
             files: ["docs/guide.md": "![a](../Resources/README/a.png)",
                     "docs/design/notes/LOG.md": "![b](before/b.png)",
                     "docs/zh-Hans/guide.md": "![a](../../Resources/README/zh-Hans/a.png)",
                     "docs/zh-Hans/more/page.md": #"<img src="../../../Resources/README/zh-Hans/c.png">"#,
                     "README.zh-Hans.md": "![d](Resources/README/zh-Hans/d.png)"],
             expect: ["Resources/README/a.png": ["docs/guide.md"], "docs/design/notes/before/b.png": ["docs/design/notes/LOG.md"],
                      "Resources/README/zh-Hans/a.png": ["docs/zh-Hans/guide.md"],
                      "Resources/README/zh-Hans/c.png": ["docs/zh-Hans/more/page.md"],
                      "Resources/README/zh-Hans/d.png": ["README.zh-Hans.md"]]),
        Case(name: "not a picture on the page: code, other sites, outside the checkout",
             files: ["docs/development.md": """
                 Write `![alt](Resources/README/inline-code.png)` for one.

                 ```html
                 <img src="Resources/README/fenced.png">
                 ```

                 1. In a list:
                     ~~~
                     ![x](Resources/README/indented-fence.png)
                     ~~~

                 ![remote](https://example.com/x.png) ![outside](../../elsewhere.png)
                 """],
             expect: [:]),
    ]

    /// A change on one branch that fails the other's check says which branch
    /// to fix, and that the problem came from there (NetworkMonitor#426). Each case is the
    /// branch the check runs for, the pull request's branch, and what each
    /// group must say, or must not.
    static let branches: [(name: String, checking: String?, head: String?, site: [String], main: [String], notSite: [String], notMain: [String])] = [
        ("a pull request into main", "main", "scanner-425",
         ["Not in this pull request's files: gh-pages changed", "name that branch scanner-425-site"], [],
         [], ["Not in this"]),
        ("a pull request into gh-pages", "gh-pages", "rename-12-site",
         [], ["Not in this pull request's files: main changed", "name this branch after that one, with -site"],
         ["Not in this"], []),
        ("a push to main", "main", nil, ["Not in this push's files"], [], [], ["Not in this"]),
        ("this Mac", nil, nil, [], [], ["Not in this"], ["Not in this"]),
    ]

    /// gh-pages renamed two shots main's list names, and added a picture it
    /// didn't list: what each branch's check says.
    static func runBranches() throws -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coverage-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let site = root.appendingPathComponent("site"), repo = root.appendingPathComponent("app")
        for (path, text) in [
            "site/index.html": #"<img src="assets/popover.png"><img src="assets/extra.png">"#,
            "site/assets/popover.png": "", "site/assets/extra.png": "",
            "app/README.md": #"![Demo](Resources/README/demo.gif) ![Speed](Resources/README/speed.png)"#,
            "app/Resources/README/demo.gif": "", "app/Resources/README/speed.png": "",
        ] {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data("""
            {"app": "/Applications/NetworkMonitor.app", "bundle": "x",
             "shots": [{"name": "popover", "file": "assets/popover.png", "open": [], "window": "x"}]}
            """.utf8))
        let repoAssets = try JSONDecoder().decode(RepoAssets.self, from: Data("""
            {"assets": [{"file": "Resources/README/demo.gif", "shows": ["popover-subprocesses"], "made": "1.28.1"},
                        {"file": "Resources/README/speed.png", "copy": "speed-test-result"}]}
            """.utf8))
        let found = try Coverage.problems(manifest: manifest, site: site, repoAssets: repoAssets, repo: repo)
        let renamed = "in shots/shots.json on gh-pages. If a change there renamed or removed it, "
            + "change \(repoAssetsPath) on main to match"
        if !(found.problems[..<found.onMain].count == 1 && found.problems[0].hasPrefix("assets/extra.png (index.html) isn't listed")) {
            failures.append("branches: gh-pages' problems are \(found.problems[..<found.onMain]); expected assets/extra.png isn't listed")
        }
        if !(found.problems[found.onMain...].count == 2 && found.problems[found.onMain...].allSatisfy { $0.contains(renamed) }) {
            failures.append("branches: main's problems are \(found.problems[found.onMain...]); expected two saying \"\(renamed)\"")
        }
        for test in branches {
            let lines = Coverage.report(found.problems, onMain: found.onMain, checking: test.checking, head: test.head)
            guard let siteAt = lines.firstIndex(where: { $0.hasPrefix("On gh-pages ") }),
                  let mainAt = lines.firstIndex(where: { $0.hasPrefix("On main ") }), siteAt < mainAt else {
                failures.append("branches, \(test.name): no group for each branch, gh-pages first: \(lines)")
                continue
            }
            let groups = [("gh-pages", lines[siteAt..<mainAt].joined(separator: "\n"), test.site, test.notSite),
                          ("main", lines[mainAt...].joined(separator: "\n"), test.main, test.notMain)]
            for (branch, text, says, never) in groups {
                for line in says where !text.contains(line) {
                    failures.append("branches, \(test.name): \(branch)'s group doesn't say \"\(line)\": \(text)")
                }
                for line in never where text.contains(line) {
                    failures.append("branches, \(test.name): \(branch)'s group says \"\(line)\": \(text)")
                }
            }
        }
        return failures
    }

    /// What failed, one line each.
    static func run() throws -> [String] {
        // The config these cases are written for, whatever the project's.
        config = Config()
        config.siteURL = "https://example.github.io/App/"
        config.repoAssets = "Resources/README/assets.json"
        var failures = try runBranches()
        let fm = FileManager.default
        for (kind, cases) in [("site", site), ("README and docs", repo)] {
            for test in cases {
                let root = fm.temporaryDirectory.appendingPathComponent("coverage-test-" + UUID().uuidString)
                defer { try? fm.removeItem(at: root) }
                for (path, text) in test.files {
                    let file = root.appendingPathComponent(path)
                    try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try text.write(to: file, atomically: true, encoding: .utf8)
                }
                let found = kind == "site" ? try Coverage.siteUses(root) : try Coverage.repoUses(root)
                if found != test.expect {
                    func show(_ u: [String: Set<String>]) -> String {
                        u.isEmpty ? "nothing" : u.sorted { $0.key < $1.key }
                            .map { "\($0.key) (\($0.value.sorted().joined(separator: ", ")))" }.joined(separator: ", ")
                    }
                    failures.append("\(kind), \(test.name): found \(show(found)); expected \(show(test.expect))")
                }
            }
        }
        return failures
    }
}

// MARK: - Drawn by the project

/// The manifest's `render` (product-kit#8): how the project draws its own pictures.
/// `{out}` in either command is the folder the drawings go in. Both run in the
/// project's checkout.
struct Render: Decodable {
    /// Builds what draws them, such as `["./build.sh"]`. Optional.
    var build: [String]?
    /// Draws every picture into `{out}`, out of sight and from fixed data:
    /// `["build/App.app/Contents/MacOS/App", "--snapshot", "shots/demo.json", "{out}"]`.
    var command: [String]
}

/// Pictures the project draws itself, from fixed data with a fixed clock, out of
/// sight (product-kit#8). A drawing that differs from its picture by a pixel means
/// the interface changed, since nothing else can: so `check` compares them, and
/// `update` copies the ones that differ. No app is opened, nothing is shown, and
/// no Mac lane is taken.
enum Rendered {
    /// A shot of a manifest with `render`: its picture and the drawing it's from.
    struct Shot: Decodable {
        var name: String
        var file: String
        var render: String
    }

    /// How long each command may take before it's stopped.
    static let buildLimit: TimeInterval = 20 * 60, drawLimit: TimeInterval = 10 * 60

    static func run(_ command: String, names: Set<String>, manifest: Manifest, render: Render, site: URL, repo: URL) -> Int32 {
        guard ["check", "update"].contains(command) else {
            print("\(command): not for pictures the project draws itself (the manifest's `render`); check and update are")
            return 2
        }
        let shots = manifest.shots.filter { names.isEmpty || names.contains($0.name) }
        let unknown = names.subtracting(manifest.shots.map(\.name))
        if !unknown.isEmpty || shots.isEmpty {
            print("\(command): no shot named \((unknown.isEmpty ? names : unknown).sorted().joined(separator: ", "))")
            return 2
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shots-kit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            func expand(_ argv: [String]) -> [String] { argv.map { $0.replacingOccurrences(of: "{out}", with: out.path) } }
            if let build = render.build, !build.isEmpty {
                print("building: \(build.joined(separator: " "))")
                try runCommand(expand(build), in: repo, limit: buildLimit, what: "the build")
            }
            print("drawing: \(render.command.joined(separator: " "))")
            try runCommand(expand(render.command), in: repo, limit: drawLimit, what: "the drawing")
        } catch {
            print("\(command): \(error)")
            return 2
        }

        var changed: [String] = [], missing: [String] = []
        for shot in shots {
            guard let drawing = shot.render else { continue }
            let drawn = out.appendingPathComponent(drawing)
            guard FileManager.default.fileExists(atPath: drawn.path) else {
                print("\(shot.name): the drawing made no \(drawing)")
                missing.append(shot.name)
                continue
            }
            let picture = site.appendingPathComponent(shot.file ?? "")
            guard let difference = compare(drawn, picture) else {
                print("\(shot.name): unchanged")
                continue
            }
            changed.append(shot.name)
            if command == "update" {
                do {
                    try FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: picture.path) { try FileManager.default.removeItem(at: picture) }
                    try FileManager.default.copyItem(at: drawn, to: picture)
                    print("\(shot.name): redrawn (\(difference)), \(shot.file ?? "")")
                } catch {
                    print("\(shot.name): couldn't write \(shot.file ?? ""): \(error)")
                    missing.append(shot.name)
                }
            } else {
                print("\(shot.name): changed: \(difference)")
            }
        }
        // What's made by hand from a window that changed: remade by hand, when asked.
        let handMade = (manifest.assets ?? []).compactMap { asset -> String? in
            let shows = (asset.shows ?? []).filter(changed.contains)
            return shows.isEmpty ? nil : "\(asset.file) (shows \(shows.joined(separator: ", ")))"
        }
        if !handMade.isEmpty {
            print("Made by hand, and showing what changed; remake by hand when asked:")
            handMade.forEach { print("  " + $0) }
        }
        let total = shots.filter { $0.render != nil }.count
        if command == "check" {
            print(changed.isEmpty ? "check: all \(total) pictures are as drawn"
                                  : "check: \(changed.count) of \(total) pictures differ from the drawing; `shots-kit update` copies the drawings")
            return missing.isEmpty ? (changed.isEmpty ? 0 : 1) : 2
        }
        print(changed.isEmpty ? "update: all \(total) pictures were as drawn" : "update: redrew \(changed.count) of \(total)")
        return missing.isEmpty ? 0 : 2
    }

    /// Runs `argv` in `dir`, stopped after `limit` seconds; throws with the end of
    /// its output when it fails.
    static func runCommand(_ argv: [String], in dir: URL, limit: TimeInterval, what: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timer)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        timer.cancel()
        if p.terminationReason == .uncaughtSignal, p.terminationStatus == SIGTERM {
            throw Failure("\(what) took more than \(Int(limit / 60)) minutes, so it was stopped")
        }
        guard p.terminationStatus == 0 else {
            let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
            throw Failure("\(what) failed (exit \(p.terminationStatus)):\n\(tail)")
        }
    }

    /// How a drawing differs from its picture, or nil when it doesn't.
    static func compare(_ drawn: URL, _ picture: URL) -> String? {
        guard let a = try? Data(contentsOf: drawn) else { return "no drawing" }
        guard let b = try? Data(contentsOf: picture) else { return "a new picture" }
        if a == b { return nil }
        guard let x = pixels(a) else { return "the drawing isn't an image" }
        guard let y = pixels(b) else { return "the picture isn't an image" }
        if x.width != y.width || x.height != y.height {
            return "its size, \(y.width)×\(y.height) to \(x.width)×\(x.height) pixels"
        }
        // The same pixels written differently (another PNG encoder) aren't a change.
        var count = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<x.height {
            for col in 0..<x.width {
                let i = (row * x.width + col) * 4
                var differs = false
                for k in 0..<4 where abs(Int(x.bytes[i + k]) - Int(y.bytes[i + k])) > 2 { differs = true; break }
                guard differs else { continue }
                count += 1
                minX = min(minX, col); maxX = max(maxX, col); minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard count > 0 else { return nil }
        return "\(count) pixels differ, within \(maxX - minX + 1)×\(maxY - minY + 1) at (\(minX), \(minY)) of \(x.width)×\(x.height)"
    }

    /// An image's pixels as sRGB RGBA, 8 bits each.
    static func pixels(_ data: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (w, h, bytes) : nil
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
struct ShotsKit {
    static func main() async {
        _ = NSApplication.shared   // ScreenCaptureKit needs a connection to the window server
        // Line by line into a log too, so a run in the background says what it waits for.
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        if args.first == "version" { print(shotsKitVersion); exit(0) }
        // The project's checkout, for its config and the README's and the
        // docs' assets: this one.
        var repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let i = args.firstIndex(of: "--repo"), i + 1 < args.count {
            repo = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
        }
        repoRoot = repo
        config = Config.load(repo: repo)
        // The site's checkout: `--site`, or the config's, from the main checkout.
        var givenSite: URL?
        if let i = args.firstIndex(of: "--site"), i + 1 < args.count {
            givenSite = URL(fileURLWithPath: args[i + 1]); args.removeSubrange(i...(i + 1))
        } else if let path = config.site {
            let common = runTool("/usr/bin/git", ["-C", repo.path, "rev-parse", "--path-format=absolute", "--git-common-dir"])
            let main = common.status == 0
                ? URL(fileURLWithPath: common.output.trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent()
                : repo
            givenSite = URL(fileURLWithPath: path, relativeTo: main).standardizedFileURL
        }
        // Another copy of the app than the manifest's, such as a development
        // build of a version not yet released.
        var app: String?
        if let i = args.firstIndex(of: "--app"), i + 1 < args.count {
            app = args[i + 1]; args.removeSubrange(i...(i + 1))
        }
        // One language only: `en`, or a language's code (NetworkMonitor#431). All of them otherwise.
        var only: String?
        // A check compares looks too (NetworkMonitor#423), which needs each window in
        // front and active: only while the Mac is idle (NetworkMonitor#475), so a look it
        // can't take is reported as not taken (NetworkMonitor#521).
        if let i = args.firstIndex(of: "--look") { compareLooks = true; args.remove(at: i) }
        if let i = args.firstIndex(of: "--wait-away"), i + 1 < args.count {
            guard let minutes = Double(args[i + 1]), minutes >= 0, minutes <= 240 else {
                print("--wait-away takes minutes, at most 240")
                exit(2)
            }
            waitAway = minutes; args.removeSubrange(i...(i + 1))
        }
        if let i = args.firstIndex(of: "--language"), i + 1 < args.count {
            only = args[i + 1]; args.removeSubrange(i...(i + 1))
        }
        guard let command = args.first, ["check", "update", "tree", "audit", "coverage", "coverage-test", "readme", "record"].contains(command) else {
            print("usage: shots-kit check [--look]|update|audit [names…]|tree <name>|record <names…>|coverage|coverage-test|readme [--site DIR] [--repo DIR] [--app APP] [--language CODE] [--wait-away MINUTES]|version")
            exit(2)
        }
        // No site: the manifest is the project's own (product-kit#8).
        if givenSite == nil, command != "coverage-test" { manifestInRepo = true }
        let site = givenSite ?? repo
        let names = Set(args.dropFirst())
        if command == "record", names.isEmpty {
            print("record: name the windows whose marks changed; recording every tree would hide a real change")
            exit(2)
        }
        // With the manifest in the repo, it lists the README's assets itself.
        let repoAssets = manifestInRepo ? nil
            : try? JSONDecoder().decode(RepoAssets.self, from: Data(contentsOf: repo.appendingPathComponent(repoAssetsPath)))

        // Made-up pages only: where `coverage` looks for media (NetworkMonitor#425).
        if command == "coverage-test" {
            do {
                let failures = try CoverageTests.run()
                let count = CoverageTests.site.count + CoverageTests.repo.count + CoverageTests.branches.count
                if failures.isEmpty {
                    print("coverage-test: \(count) cases passed")
                    exit(0)
                }
                print("coverage-test: \(failures.count) of \(count) cases failed:")
                failures.forEach { print("  " + $0) }
                exit(1)
            } catch {
                print("coverage-test: \(error)")
                exit(2)
            }
        }
        // Files only, so first, before anything that needs the app.
        if command == "coverage" {
            do {
                let manifest = try loadManifest(site)
                if !manifestInRepo, repoAssets == nil, FileManager.default.fileExists(atPath: repo.appendingPathComponent(repoAssetsPath).path) {
                    throw Failure("\(repoAssetsPath) doesn't read as a list of assets")
                }
                let found = try Coverage.problems(manifest: manifest, site: site, repoAssets: repoAssets, repo: repo)
                if found.problems.isEmpty {
                    print("coverage: \(found.summary), all accounted for")
                } else {
                    print("coverage: every image, GIF and video a page uses must be listed, so a change to the window it shows can't leave it stale:")
                    // The branch a pull request goes into, or a push went to, on GitHub.
                    let env = ProcessInfo.processInfo.environment
                    let checking = [env["GITHUB_BASE_REF"], env["GITHUB_REF_NAME"]]
                        .compactMap { $0 }.first { !$0.isEmpty }.flatMap { [config.repoBranch, config.siteBranch].contains($0) ? $0 : nil }
                    let head = env["GITHUB_HEAD_REF"].flatMap { $0.isEmpty ? nil : $0 }
                    Coverage.report(found.problems, onMain: found.onMain, checking: checking, head: head).forEach { print($0) }
                }
                if !found.stale.isEmpty {
                    print("Out of date, each waiting on its issue:")
                    found.stale.forEach { print("  " + $0) }
                }
                exit(found.problems.isEmpty ? 0 : 1)
            } catch {
                print("coverage: \(error)")
                exit(2)
            }
        }
        // Files only too: the README's copies of the site's pictures.
        if command == "readme" {
            do {
                let manifest = try loadManifest(site)
                let languages: [Language?] = [nil] + (manifest.languages ?? []).map { $0 }
                var copied: [String] = []
                for language in languages where only == nil || only == (language?.code ?? "en") {
                    copied += try copyToRepo(manifest: manifest, site: site, repo: repo, repoAssets: repoAssets, language: language)
                }
                print(copied.isEmpty ? "readme: the README's pictures are the site's already"
                                     : "readme: copied the site's pictures to " + copied.joined(separator: ", "))
                exit(0)
            } catch {
                print("readme: \(error)")
                exit(2)
            }
        }
        // Drawn by the project: no app, no screen, no lanes (product-kit#8).
        if let manifest = try? loadManifest(site), let render = manifest.render {
            exit(Rendered.run(command, names: names, manifest: manifest, render: render, site: site, repo: repo))
        }
        // One run at a time: each quits and relaunches the app, so two at once,
        // from two terminals or two sessions, spoil each other's windows.
        let lock = open(NSHomeDirectory() + "/Library/Caches/shots-kit.lock", O_CREAT | O_RDWR, 0o644)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            print("shots-kit: another run is driving an app; try again once it's done")
            exit(2)
        }
        do {
            guard AXIsProcessTrusted() else { throw Failure("give this terminal Accessibility in System Settings › Privacy & Security") }
            var manifest = try loadManifest(site)
            if let app { manifest.app = app }
            // Trees and pictures are read on a Retina screen; on a 1x one
            // they'd differ from the records without any change (NetworkMonitor#487).
            if stage() == nil, ["check", "update", "record"].contains(command) {
                throw Failure("no Retina screen to read the windows on: the records are read on one")
            }
            // Put back as it was, the installed copy, even after a run with
            // another copy (`--app`, NetworkMonitor#506).
            var installed = manifest
            installed.app = try loadManifest(site).app
            let mac = Mac(manifest: manifest, installed: installed, command: command)
            // However the run ends: Ctrl-C or a kill too.
            for sig in [SIGINT, SIGTERM, SIGHUP] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler { mac.end(); exit(128 + sig) }
                source.resume()
                signalSources.append(source)
            }
            var session = Session(manifest: manifest)
            // Reading the tree needs no focus; a picture shows the window active.
            session.background = ["check", "tree", "audit"].contains(command) && !(command == "check" && compareLooks)
            var status: Int32 = 0
            // English, then each language's page with the same shots in it.
            let languages: [Language?] = [nil] + (manifest.languages ?? []).map { $0 }
            for language in languages where only == nil || only == (language?.code ?? "en") {
                if let language { print("\n\(language.code), for \(language.page):") }
                do {
                    let translator = try language.map { try Translator(app: manifest.app, language: $0) }
                    let s = try await run(command, names: names, manifest: manifest, session: session, mac: mac, site: site,
                                          repo: repo, repoAssets: repoAssets, language: language, translator: translator)
                    status = max(status, s)
                    if let missing = translator?.missing, !missing.isEmpty {
                        print("  kept in English, as the app's \(language!.code) table doesn't have them "
                              + "(a name is fine; otherwise add it to the language's `specs`): "
                              + missing.sorted().joined(separator: " | "))
                    }
                } catch { status = 2; print("shots-kit: \(error)") }
            }
            mac.end()
            exit(status)
        } catch {
            print("shots-kit: \(error)")
            exit(2)
        }
    }

    static func run(_ command: String, names: Set<String>, manifest: Manifest, session: Session, mac: Mac, site: URL, repo: URL,
                    repoAssets: RepoAssets?, language: Language? = nil, translator: Translator? = nil) async throws -> Int32 {
        var shots = manifest.shots.filter { names.isEmpty || names.contains($0.name) }
        if shots.isEmpty { throw Failure("no shot named \(names.sorted().joined(separator: ", "))") }
        if let language, let translator { shots = shots.map { $0.localized(language, translator) } }
        // Each language's trees apart, as its labels differ.
        let trees = site.appendingPathComponent(language.map { "shots/trees/\($0.code)" } ?? "shots/trees")
        try FileManager.default.createDirectory(at: trees, withIntermediateDirectories: true)
        var page = try Page(site: site, path: language?.page ?? "index.html", up: language?.up ?? "")
        var changed: [String] = [], flagged: [String] = [], failed: [String] = []
        /// Windows whose look differs from their picture's (NetworkMonitor#423).
        var looks: [String] = []
        var problems: [String] = []
        var cached: (args: [String], window: String)?

        // What's made by hand from each window, on the site and in the README
        // and docs (NetworkMonitor#413), to name when the window changes.
        // Named once, from English: they're remade from that window in every
        // language at the same time.
        var handMade: [String: [String]] = [:]
        if language == nil {
            for shot in manifest.shots { handMade[shot.name, default: []] += shot.flags ?? [] }
            for asset in manifest.assets ?? [] {
                for name in asset.shows ?? [] where !(handMade[name] ?? []).contains(asset.file) { handMade[name, default: []].append(asset.file) }
            }
            for asset in repoAssets?.assets ?? [] {
                for name in asset.shows ?? [] { handMade[name, default: []].append("\(asset.file) (main)") }
            }
        }

        // The version each record was taken from (NetworkMonitor#421), English only: what's
        // made by hand is checked against it.
        var versions = language == nil ? Versions.read(trees) : [:]
        let appVersion = Versions.app(manifest.app)

        var current: [String: [String]] = [:]
        // One shot, read and taken.
        func take(_ shot: Shot) async throws {
            // A costly shot follows its base window: retaken only when the
            // base's tree differs from the one it was last taken with.
            var baseTree: [String]?
            if let base = shot.when, command == "record" {
                // Can't be read without taking it (a speed test): record
                // only that it was taken with the base window as it reads
                // now, so a new mark there doesn't retake it.
                guard let now = current[base] else { print("\(shot.name): name \(base) too, to record its base"); return }
                try (now.joined(separator: "\n") + "\n").write(
                    to: trees.appendingPathComponent("\(shot.name).base.txt"), atomically: true, encoding: .utf8)
                print("\(shot.name): recorded \(base) as it was taken with")
                return
            }
            if let base = shot.when {
                let baseFile = trees.appendingPathComponent("\(shot.name).base.txt")
                let taken = (try? String(contentsOf: baseFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
                guard let now = current[base] else {
                    print("\(shot.name): needs \(base) checked first, in the same run"); return
                }
                let named = names.contains(shot.name)
                if taken == now && !named { print("\(shot.name): unchanged (\(base) is)"); return }
                if command != "update" || (taken != nil && !named && command == "check") {
                    print("\(shot.name): \(base) changed, so it's retaken on update")
                    changed.append(shot.name); return
                }
                if command != "update" { return }
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
            // On the stage, before anything reads it (NetworkMonitor#487).
            session.place(window)
            if let spec = shot.skipIf, find(spec, in: window) != nil {
                print("\(shot.name): skipped while \(spec) shows; it's tried again on the next update")
                cached = nil
                return
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
            if command == "tree" { print(now.joined(separator: "\n")); return }
            if command == "audit" {
                let found = AccessibilityAudit.audit(window).map { "\(shot.window): \($0)" }
                print("\(shot.name): " + (found.isEmpty ? "nothing missing" : "\(found.count) to fix"))
                problems += found
                return
            }

            let treeFile = trees.appendingPathComponent("\(shot.name).txt")
            let before = (try? String(contentsOf: treeFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
            let differs = before != now
            // The look, against the one kept from the picture (NetworkMonitor#423).
            let lookFile = trees.appendingPathComponent("\(shot.name).look")
            if let file = shot.file, command == "record" {
                // From the picture, with the window's masks laid on it as
                // it is now: the picture is what the site shows.
                let fresh = try await session.look(window, shot)
                if let picture = NSImage(contentsOf: site.appendingPathComponent(file))?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil),
                   picture.width == fresh.picture.width, picture.height == fresh.picture.height,
                   let look = Look(picture, masks: fresh.masks) {
                    try look.text.write(to: lookFile, atomically: true, encoding: .utf8)
                    let d = fresh.look.differing(from: look)
                    print("\(shot.name): kept its look, from \(file)" + (d.map { $0.count > 0 ? " (\($0.count) of \($0.of) cells differ now)" : "" } ?? ""))
                } else {
                    print("\(shot.name): \(file) isn't the window's size now, so its look isn't kept; retake it")
                }
            } else if shot.file != nil,
                      // An update compares what it won't retake anyway.
                      (command == "check" && compareLooks)
                        || (command == "update" && !(differs || names.contains(shot.name) || shot.always == true)),
                      let kept = (try? String(contentsOf: lookFile, encoding: .utf8)).flatMap(Look.init(text:)) {
                let fresh = try await session.look(window, shot)
                if let d = fresh.look.differing(from: kept) {
                    if d.count > Look.threshold {
                        looks.append("\(shot.name): \(d.count) of \(d.of) cells differ")
                    } else if d.count > 0 {
                        print("\(shot.name): looks the same (\(d.count) of \(d.of) cells differ, within \(Look.threshold))")
                    }
                } else {
                    looks.append("\(shot.name): its picture is \(kept.width)×\(kept.height), the window \(fresh.look.width)×\(fresh.look.height) now")
                }
            }
            if command == "record" {
                try record(shot, now: now, before: before, handMade: handMade[shot.name] ?? [], trees: trees)
                return
            }
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
            let madeOnDisk = (try? String(contentsOf: madeFile, encoding: .utf8))?.split(separator: "\n").map(String.init)
            let made = madeOnDisk ?? before
            if !hand.isEmpty, let made, made != now, !(command == "update" && named) {
                flagged += hand.map { "\($0), from \(shot.name)" }
            }
            guard command == "update", differs || named || shot.always == true || baseTree != nil else { return }
            // A window that only flags videos keeps its old tree until
            // they're remade and it's updated by name, so the reminder stays.
            if shot.file == nil, before != nil, !named { return }

            if let file = shot.file {
                // Active, with its look kept from the same capture.
                let taken = try await session.look(window, shot)
                let image = taken.picture
                // A crop leaves out the traffic lights that tell.
                if shot.crop == nil && !isActive(image, window: window) { print("  warning: \(file) shows the window inactive") }
                try writePNG(image, to: site.appendingPathComponent(file))
                try taken.look.text.write(to: lookFile, atomically: true, encoding: .utf8)
                page.setSize(of: file, pixels: CGSize(width: image.width, height: image.height))
                print("  retook \(file) (\(image.width)×\(image.height))")
                // And the README's copy of it, in this language (NetworkMonitor#434).
                for copy in try copyToRepo(manifest: manifest, site: site, repo: repo, repoAssets: repoAssets,
                                           language: language, shots: [shot.name]) {
                    print("  copied it to \(copy)")
                }
            }
            let windowFrame = frame(window) ?? .zero
            for area in shot.areas ?? [] {
                guard var element = find(area.element, in: window) else { print("  warning: no \(area.element) for \(area.match)"); continue }
                if area.parent == true, let p = parent(of: element) { element = p }
                guard let r = frame(element) else { continue }
                page.place(area, at: r.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY), windowWidth: windowFrame.width)
            }
            // Each record keeps its version while it holds the same tree.
            let treeName = treeFile.lastPathComponent, madeName = madeFile.lastPathComponent
            if !hand.isEmpty {
                if named {
                    try (now.joined(separator: "\n") + "\n").write(to: madeFile, atomically: true, encoding: .utf8)
                    versions[madeName] = (madeOnDisk == now ? versions[madeName] : before == now ? versions[treeName] : nil) ?? appVersion
                } else if madeOnDisk == nil, let before {
                    try (before.joined(separator: "\n") + "\n").write(to: madeFile, atomically: true, encoding: .utf8)
                    versions[madeName] = versions[treeName]
                }
            }
            try (now.joined(separator: "\n") + "\n").write(to: treeFile, atomically: true, encoding: .utf8)
            versions[treeName] = (before == now ? versions[treeName] : nil) ?? appVersion
            if language == nil { try Versions.write(versions, to: trees) }
            if let baseTree {
                try (baseTree.joined(separator: "\n") + "\n").write(
                    to: trees.appendingPathComponent("\(shot.name).base.txt"), atomically: true, encoding: .utf8)
            }
            // Saved as it goes, so a later failure doesn't leave a picture
            // without its size and areas.
            try page.save()
        }

        // Every window that needs nothing of the person at the Mac first, behind the others
        // and without focus. A window to bring forward or click for real while
        // someone is at the Mac isn't taken (NetworkMonitor#521): it's reported as not taken, and
        // why, and the run goes on and ends as it would without it. Only with
        // `--wait-away MINUTES` does it wait, silently and with the lanes free,
        // in case the Mac is left idle or locked anyway, then takes those alone
        // (NetworkMonitor#504).
        var queue = shots
        var notTaken: [String] = []
        let deadline = Date().addingTimeInterval(waitAway * 60)
        try mac.hold("reading windows")
        while true {
            cached = nil
            var later: [Shot] = [], reasons: [String] = []
            for shot in queue {
                // A costly shot follows its base window, so waits with it.
                if let base = shot.when, later.contains(where: { $0.name == base }) { later.append(shot); continue }
                do { try await take(shot) } catch let away as NeedsAway {
                    later.append(shot)
                    reasons.append("\(shot.name) needs \(away.what)")
                    cached = nil
                } catch {
                    print("\(shot.name): \(error)")
                    failed.append(shot.name)
                    cached = nil
                }
            }
            if later.isEmpty { break }
            queue = later
            mac.letGo()
            if waitAway > 0 {
                print("\n" + reasons.joined(separator: "; ") + ": these need the screen while you're using it, so the run "
                      + "waits up to \(String(format: "%g", waitAway)) min, silently with the lanes free, in case it's left idle or locked")
            }
            guard waitAway > 0, try mac.holdOnceAway(later.map(\.name).joined(separator: ", ") + ", with the Mac idle",
                                                     until: deadline) else {
                notTaken = reasons
                break
            }
        }

        if command == "update" {
            page.stampAssets(site: site)
            try page.save()
        }
        // Advice, not a failure: it reads pixels, which the Mac can change
        // without the app (NetworkMonitor#423).
        if !looks.isEmpty {
            print("\nThese look different from their pictures (a colour, an icon, spacing, a font), whatever their trees say. "
                  + "Compare them by eye, and retake the ones that changed with `update <names>`:")
            looks.forEach { print("  " + $0) }
        }
        if !flagged.isEmpty {
            print("\nThese show a window that changed since they were made. Remake them by hand, then run `update` with the window's name:")
            Set(flagged).sorted().forEach { print("  \($0)") }
        }
        // Not a failure, and nothing to hold a release or a review on (NetworkMonitor#521):
        // what's left is said, and taken on a later run.
        if !notTaken.isEmpty {
            print("\nNot taken: they need the real screen (a window brought forward, or a real click), and the Mac was "
                  + "in use. Their pictures and trees are as they were; a later run takes them:")
            notTaken.forEach { print("  " + $0) }
        }
        if command == "audit", !problems.isEmpty {
            // The same row repeats down a list; say it once.
            var seen = Set<String>()
            print("\nFor VoiceOver:")
            for p in problems where seen.insert(p).inserted { print("  " + p) }
        }
        if !failed.isEmpty { return 2 }
        if command == "record" { return 0 }
        if command == "audit" { return problems.isEmpty ? 0 : 1 }
        return command == "check" && !(changed.isEmpty && flagged.isEmpty) ? 1 : 0
    }

    /// Records a window's tree as it reads now, without retaking its picture
    /// (NetworkMonitor#416): for after a mark in the manifest changed what's data or left
    /// out, such as the Mac's connection. The diff it prints should be only
    /// what the new marks cover. A reminder to remake what's made by hand
    /// stays: the tree each was made from is updated only if it was the
    /// window's tree, and a window that only flags videos keeps its old tree
    /// while they're waiting to be remade.
    static func record(_ shot: Shot, now: [String], before: [String]?, handMade: [String], trees: URL) throws {
        let treeFile = trees.appendingPathComponent("\(shot.name).txt")
        let madeFile = trees.appendingPathComponent("\(shot.name).made.txt")
        if shot.file == nil, !handMade.isEmpty, let before, before != now {
            print("\(shot.name): kept, as what's made from it is waiting to be remade (\(handMade.joined(separator: ", ")))")
            return
        }
        if let before, before == now { print("\(shot.name): unchanged"); return }
        print("\(shot.name): recorded" + (before == nil ? "" : ", as it reads now:"))
        if let before { diff(before, now).prefix(40).forEach { print($0) } }
        let text = now.joined(separator: "\n") + "\n"
        if let made = (try? String(contentsOf: madeFile, encoding: .utf8))?.split(separator: "\n").map(String.init),
           made == before {
            try text.write(to: madeFile, atomically: true, encoding: .utf8)
        }
        try text.write(to: treeFile, atomically: true, encoding: .utf8)
    }
}

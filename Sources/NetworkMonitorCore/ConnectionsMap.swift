import AppKit
import ServerDirectory
import SwiftUI

/// The world, shaded by how much data went to each country (#113).
///
/// Drawn by the app from Natural Earth's outlines in `Resources/Geo/world.bin`:
/// no map tiles and no network access. Calm by default, a summary of the
/// period; with Live on, lines pulse to the countries answering right now,
/// and only then does the map redraw on its own.
struct ConnectionsMap: View {
    @ObservedObject var model: ConnectionsViewModel
    /// Not `@State`, which needs Xcode from the macOS 27 SDK on.
    @StateObject private var state = ConnectionsMapState()

    var body: some View {
        GeometryReader { geometry in
            let frame = MapFrame(size: geometry.size, zoom: state.zoom, pan: state.pan)
            ZStack {
                if model.isLive {
                    TimelineView(.periodic(from: .now, by: 1.0 / 20)) { timeline in
                        canvas(frame, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    canvas(frame, time: nil)
                }
                overlays(frame)
            }
            .contentShape(Rectangle())
            .gesture(dragOrTap(frame))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { state.setZoom(state.zoomAtStart * $0, size: geometry.size) }
                    .onEnded { _ in state.zoomAtStart = state.zoom })
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    state.pointer = location
                    state.hovered = WorldShapes.shared?.country(at: frame.world(location),
                                                                dotRadius: 8 / frame.scale)
                case .ended:
                    state.hovered = nil
                }
            }
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("World map of \(model.geography.countries.count) countries your apps reached. "
                            + "The list has the same, country by country.")
    }

    // MARK: Drawing

    private func canvas(_ frame: MapFrame, time: TimeInterval?) -> some View {
        Canvas { context, _ in
            guard let shapes = WorldShapes.shared else { return }
            let geography = model.geography
            let largest = geography.largest
            let picked = model.selected[.country]?.key
            let transform = frame.transform
            let border = Color(nsColor: .windowBackgroundColor)

            for shape in shapes.countries where !shape.isDot {
                let path = shape.path.applying(transform)
                context.fill(path, with: .color(Self.fill(geography.countries[shape.code] ?? 0, of: largest)))
                context.stroke(path, with: .color(border), lineWidth: 0.5)
            }
            // Countries too small to see at this zoom, and those drawn inside
            // another, get a dot, but only if something went there.
            for shape in shapes.countries where !shape.code.isEmpty {
                guard let bytes = geography.countries[shape.code], bytes > 0,
                      shape.isDot || shape.extent * frame.scale < 4 else { continue }
                let centre = frame.point(shape.label)
                let dot = Path(ellipseIn: CGRect(x: centre.x - 3.5, y: centre.y - 3.5, width: 7, height: 7))
                context.fill(dot, with: .color(Self.fill(bytes, of: largest, minimum: 0.55)))
                context.stroke(dot, with: .color(border), lineWidth: 1)
            }
            for code in [picked, state.hovered].compactMap({ $0 }) {
                guard let shape = shapes.byCode[code] else { continue }
                if shape.isDot || shape.extent * frame.scale < 4 {
                    let centre = frame.point(shape.label)
                    context.stroke(Path(ellipseIn: CGRect(x: centre.x - 6, y: centre.y - 6, width: 12, height: 12)),
                                   with: .color(.accentColor), lineWidth: 1.5)
                } else {
                    context.stroke(shape.path.applying(transform), with: .color(.accentColor), lineWidth: 1.5)
                }
            }

            guard let home = model.homeCountry.flatMap({ shapes.byCode[$0] }) else { return }
            let origin = frame.point(home.label)
            // Lines once the list is narrowed to a company, app or server: to
            // where it went. Unnarrowed, every country would be a line.
            if model.selected[.company] != nil || model.selected[.app] != nil || model.selected[.server] != nil {
                for (code, _) in geography.countries.sorted(by: { $0.value > $1.value }).prefix(30)
                where code != home.code {
                    guard let shape = shapes.byCode[code] else { continue }
                    context.stroke(Self.arc(from: origin, to: frame.point(shape.label)),
                                   with: .color(.accentColor.opacity(0.7)), lineWidth: 1.2)
                }
            }
            if let time {
                let now = Date()
                for (code, seen) in model.liveCountries where code != home.code {
                    guard let shape = shapes.byCode[code] else { continue }
                    let destination = frame.point(shape.label)
                    let fade = max(0, 1 - now.timeIntervalSince(seen) / ConnectionsViewModel.liveWindow)
                    let arc = Self.arc(from: origin, to: destination)
                    context.stroke(arc, with: .color(.orange.opacity(0.35 * fade)), lineWidth: 1)
                    // A pulse travelling outwards, each country's on its own beat.
                    let beat = Double(abs(code.hashValue % 100)) / 100
                    let progress = (time / 1.6 + beat).truncatingRemainder(dividingBy: 1)
                    let position = Self.point(on: origin, to: destination, at: progress)
                    context.fill(Path(ellipseIn: CGRect(x: position.x - 2.5, y: position.y - 2.5,
                                                        width: 5, height: 5)),
                                 with: .color(.orange.opacity(fade)))
                }
            }
            context.stroke(Path(ellipseIn: CGRect(x: origin.x - 4, y: origin.y - 4, width: 8, height: 8)),
                           with: .color(.primary.opacity(0.8)), lineWidth: 2)
        }
    }

    /// Accent, deeper the more data went there, on a logarithmic scale: a
    /// country with a few kilobytes still shows beside one with gigabytes.
    static func fill(_ bytes: Int64, of largest: Int64, minimum: Double = 0.22) -> Color {
        guard bytes > 0, largest > 0 else { return Color.secondary.opacity(0.18) }
        let share = log(1 + Double(bytes)) / log(1 + Double(largest))
        return Color.accentColor.opacity(minimum + (0.92 - minimum) * share)
    }

    /// A curve that bows away from the straight line, like a flight path.
    static func arc(from start: CGPoint, to end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control(start, end))
        return path
    }

    static func point(on start: CGPoint, to end: CGPoint, at t: Double) -> CGPoint {
        let c = control(start, end), u = 1 - t
        return CGPoint(x: u * u * start.x + 2 * u * t * c.x + t * t * end.x,
                       y: u * u * start.y + 2 * u * t * c.y + t * t * end.y)
    }

    private static func control(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        // Perpendicular, a fifth of the distance, on whichever side is up.
        var normal = CGPoint(x: -dy * 0.2, y: dx * 0.2)
        if normal.y > 0 { normal = CGPoint(x: -normal.x, y: -normal.y) }
        return CGPoint(x: (start.x + end.x) / 2 + normal.x, y: (start.y + end.y) / 2 + normal.y)
    }

    // MARK: Overlays

    @ViewBuilder
    private func overlays(_ frame: MapFrame) -> some View {
        VStack {
            HStack {
                Spacer()
                // Live is traffic as it happens: nothing to do with what was blocked.
                if model.measure == .bytes {
                    Toggle("Live", isOn: Binding(get: { model.isLive }, set: { model.isLive = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                        .help("Lines pulse to the countries your apps reach right now")
                }
                HStack(spacing: 2) {
                    zoomButton("minus.magnifyingglass", help: "Zoom out") { state.setZoom(state.zoom / 1.5, size: frame.size) }
                    zoomButton("plus.magnifyingglass", help: "Zoom in") { state.setZoom(state.zoom * 1.5, size: frame.size) }
                    zoomButton("arrow.down.right.and.arrow.up.left", help: "The whole world") { state.reset() }
                        .disabled(state.zoom == 1 && state.pan == .zero)
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                if model.geography.everywhere > 0 {
                    Text(everywhereNote)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 280, alignment: .leading)
                        .help("These networks answer each address from whichever of their data centres is "
                              + "nearest, so no one country is where it went.")
                }
                Spacer()
            }
        }
        .padding(8)
        if let code = state.hovered {
            card(code)
                .position(cardPosition(in: frame.size))
                .allowsHitTesting(false)
        }
    }

    private var everywhereNote: String {
        let names = model.geography.everywhereCompanies
        let shown = names.prefix(2).joined(separator: " and ") + (names.count > 2 ? " and others" : "")
        if model.measure == .blocked {
            return "\(shown): \(model.format(model.geography.everywhere)) blocked, not placed on the map: "
                + "they answer from many places at once."
        }
        return "\(shown): \(model.format(model.geography.everywhere)) answered from nearby data "
            + "centres, so not placed on the map."
    }

    private func zoomButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18, height: 16) }
            .buttonStyle(.borderless)
            .help(help)
            .padding(.horizontal, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }

    private func card(_ code: String) -> some View {
        let bytes = model.geography.countries[code] ?? 0
        let companies = model.companies(inCountry: code)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let flag = ConnectionsReport.flag(code) { Text(flag) }
                Text(ConnectionsReport.countryName(code)).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text(model.format(bytes)).font(.system(size: 11)).monospacedDigit()
            }
            if companies.isEmpty {
                Text(model.measure == .blocked ? "Nothing blocked here" : "Nothing went here").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ForEach(companies.prefix(4), id: \.item.id) { company in
                    HStack {
                        Text(company.item.title).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(model.format(company.bytes)).monospacedDigit()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                if companies.count > 4 {
                    Text("and \(companies.count - 4) more").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text("Click to see only \(ConnectionsReport.countryName(code))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 3, y: 1)
    }

    /// Beside the pointer, and kept inside the map.
    private func cardPosition(in size: CGSize) -> CGPoint {
        let width: CGFloat = 210, height: CGFloat = 130
        var x = state.pointer.x + 16 + width / 2
        if x + width / 2 > size.width { x = state.pointer.x - 16 - width / 2 }
        let y = min(max(state.pointer.y, height / 2 + 4), size.height - height / 2 - 4)
        return CGPoint(x: x, y: y)
    }

    // MARK: Gestures

    /// A drag pans; a click without one narrows to the country under it.
    private func dragOrTap(_ frame: MapFrame) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if hypot(value.translation.width, value.translation.height) > 3 {
                    state.setPan(CGSize(width: state.panAtStart.width + value.translation.width,
                                        height: state.panAtStart.height + value.translation.height),
                                 size: frame.size)
                }
            }
            .onEnded { value in
                defer { state.panAtStart = state.pan }
                guard hypot(value.translation.width, value.translation.height) <= 3,
                      let code = WorldShapes.shared?.country(at: frame.world(value.location),
                                                             dotRadius: 8 / frame.scale),
                      let item = model.countryItem(code) else { return }
                model.narrow(to: item)
            }
    }
}

/// Where the map is looking, and what's under the pointer.
final class ConnectionsMapState: ObservableObject {
    @Published var zoom: CGFloat = 1
    @Published var pan: CGSize = .zero
    @Published var hovered: String?
    @Published var pointer: CGPoint = .zero
    var zoomAtStart: CGFloat = 1
    var panAtStart: CGSize = .zero

    static let maximumZoom: CGFloat = 8

    func setZoom(_ zoom: CGFloat, size: CGSize) {
        self.zoom = min(max(zoom, 1), Self.maximumZoom)
        setPan(pan, size: size)
    }

    /// Never so far that the world leaves the map.
    func setPan(_ pan: CGSize, size: CGSize) {
        let limitX = size.width * (zoom - 1) / 2 + size.width / 4
        let limitY = size.height * (zoom - 1) / 2 + size.height / 4
        self.pan = CGSize(width: min(max(pan.width, -limitX), limitX),
                          height: min(max(pan.height, -limitY), limitY))
    }

    func reset() {
        zoom = 1
        zoomAtStart = 1
        pan = .zero
        panAtStart = .zero
    }
}

/// From the projection's coordinates to the view's and back.
struct MapFrame {
    let size: CGSize
    let zoom: CGFloat
    let pan: CGSize

    var scale: CGFloat {
        min(size.width / (2 * EqualEarth.maxX), size.height / (2 * EqualEarth.maxY)) * 0.96 * zoom
    }

    private var centre: CGPoint { CGPoint(x: size.width / 2 + pan.width, y: size.height / 2 + pan.height) }

    /// North up: the projection's y grows northwards, the view's downwards.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: centre.x, y: centre.y).scaledBy(x: scale, y: -scale)
    }

    func point(_ point: WorldMap.Point) -> CGPoint {
        CGPoint(x: centre.x + point.x * scale, y: centre.y - point.y * scale)
    }

    func world(_ point: CGPoint) -> WorldMap.Point {
        WorldMap.Point(x: (point.x - centre.x) / scale, y: (centre.y - point.y) / scale)
    }
}

/// The outlines as paths, built once from the bundled map.
final class WorldShapes {
    struct Shape {
        let code: String
        let label: WorldMap.Point
        let rings: [[WorldMap.Point]]
        let path: Path
        let bounds: CGRect
        var isDot: Bool { rings.isEmpty }
        /// The larger side, in projected units: under a few points across, it's a dot.
        var extent: CGFloat { max(bounds.width, bounds.height) }
    }

    static let shared: WorldShapes? = {
        guard let url = Bundle.main.url(forResource: "Geo", withExtension: nil)?
                .appendingPathComponent("world.bin"),
              let map = try? WorldMap(contentsOf: url) else { return nil }
        return WorldShapes(map)
    }()

    let countries: [Shape]
    let byCode: [String: Shape]

    init(_ map: WorldMap) {
        countries = map.countries.map { country in
            var path = Path()
            for ring in country.rings {
                guard let first = ring.first else { continue }
                path.move(to: CGPoint(x: first.x, y: first.y))
                for point in ring.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                path.closeSubpath()
            }
            return Shape(code: country.code, label: country.label, rings: country.rings,
                         path: path, bounds: path.boundingRect)
        }
        byCode = Dictionary(countries.filter { !$0.code.isEmpty }.map { ($0.code, $0) },
                            uniquingKeysWith: { first, _ in first })
    }

    /// The country under `point`: an outline, or else the nearest dot within
    /// `dotRadius`, both in projected units.
    func country(at point: WorldMap.Point, dotRadius: Double) -> String? {
        let location = CGPoint(x: point.x, y: point.y)
        for shape in countries where !shape.isDot && !shape.code.isEmpty
        && shape.bounds.contains(location) && WorldMap.contains(point, rings: shape.rings) {
            return shape.code
        }
        return countries
            .filter { !$0.code.isEmpty && ($0.isDot || $0.extent < dotRadius * 2) }
            .map { ($0.code, hypot($0.label.x - point.x, $0.label.y - point.y)) }
            .filter { $0.1 <= dotRadius }
            .min { $0.1 < $1.1 }?.0
    }
}

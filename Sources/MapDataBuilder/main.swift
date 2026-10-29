import Foundation
import ServerDirectory

// Converts Natural Earth's 1:10m countries (public domain) into the world map
// the Connections window draws: projected with Equal Earth, simplified, and
// quantized. Run through Scripts/mapdata.sh:
//
//   MapDataBuilder <ne_10m_admin_0_countries.geojson> <output file>
//
// Natural Earth changes rarely, so the output is committed, like the DB-IP data.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: MapDataBuilder <countries.geojson> <output>\n".utf8))
    exit(2)
}

/// How far, in projected units, an outline may stray to lose a point. The map
/// is about 5.4 units wide, so at 1,200 points across this is a third of a point, and still under one zoomed in twice.
let tolerance = 0.0015

/// Places DB-IP can name that Natural Earth draws inside another country or
/// not at all, as dots where they are: (code, longitude, latitude).
let dots: [(String, Double, Double)] = [
    ("BQ", -68.27, 12.20),    // Caribbean Netherlands, at Bonaire
    ("BV", 3.36, -54.42),     // Bouvet Island
    ("CC", 96.84, -12.17),    // Cocos (Keeling) Islands
    ("CX", 105.62, -10.49),   // Christmas Island
    ("GF", -53.13, 3.93),     // French Guiana
    ("GP", -61.58, 16.25),    // Guadeloupe
    ("MQ", -61.02, 14.64),    // Martinique
    ("RE", 55.54, -21.12),    // Réunion
    ("SJ", 15.65, 78.22),     // Svalbard and Jan Mayen
    ("TK", -171.85, -9.20),   // Tokelau
    ("YT", 45.17, -12.83),    // Mayotte
]

func project(_ coordinate: [Double]) -> WorldMap.Point {
    let (x, y) = EqualEarth.project(longitude: coordinate[0], latitude: coordinate[1])
    return WorldMap.Point(x: x, y: y)
}

/// Douglas–Peucker, without recursion: keeps the points an outline can't lose
/// without straying more than `tolerance`.
func simplify(_ points: [WorldMap.Point]) -> [WorldMap.Point] {
    guard points.count > 3 else { return points }
    var keep = Array(repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    var stack = [(0, points.count - 1)]
    while let (first, last) = stack.popLast() {
        guard last > first + 1 else { continue }
        let a = points[first], b = points[last]
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        var farthest = first, distance = 0.0
        for index in (first + 1)..<last {
            let p = points[index]
            // A closed ring starts and ends on the same point, which is no
            // line to measure from: then it's the distance to that point.
            let d = length < .ulpOfOne
                ? hypot(p.x - a.x, p.y - a.y)
                : abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / length
            if d > distance { distance = d; farthest = index }
        }
        if distance > tolerance {
            keep[farthest] = true
            stack.append((first, farthest))
            stack.append((farthest, last))
        }
    }
    return points.indices.filter { keep[$0] }.map { points[$0] }
}

let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
guard let features = (json as? [String: Any])?["features"] as? [[String: Any]] else {
    FileHandle.standardError.write(Data("not a GeoJSON feature collection\n".utf8))
    exit(1)
}

var countries: [WorldMap.Country] = []
var pointsIn = 0, pointsOut = 0
for feature in features {
    guard let properties = feature["properties"] as? [String: Any],
          let geometry = feature["geometry"] as? [String: Any],
          let type = geometry["type"] as? String else { continue }
    let iso = properties["ISO_A2_EH"] as? String ?? "-99"
    let code = iso.count == 2 ? iso : ""
    let polygons: [[[[Double]]]]
    switch type {
    case "Polygon":      polygons = [geometry["coordinates"] as? [[[Double]]] ?? []]
    case "MultiPolygon": polygons = geometry["coordinates"] as? [[[[Double]]]] ?? []
    default:             continue
    }
    var rings: [[WorldMap.Point]] = []
    for polygon in polygons {
        for ring in polygon {
            pointsIn += ring.count
            let simplified = simplify(ring.map(project))
            // Fewer than four points is a sliver, not an island.
            guard simplified.count >= 4 else { continue }
            pointsOut += simplified.count
            rings.append(simplified)
        }
    }
    let longitude = properties["LABEL_X"] as? Double, latitude = properties["LABEL_Y"] as? Double
    let label = longitude.flatMap { lon in latitude.map { project([lon, $0]) } }
        ?? rings.first.map { ring in
            WorldMap.Point(x: ring.map(\.x).reduce(0, +) / Double(ring.count),
                           y: ring.map(\.y).reduce(0, +) / Double(ring.count))
        }
        ?? WorldMap.Point(x: 0, y: 0)
    countries.append(WorldMap.Country(code: code, label: label, rings: rings))
}
for (code, longitude, latitude) in dots where !countries.contains(where: { $0.code == code }) {
    countries.append(WorldMap.Country(code: code, label: project([longitude, latitude]), rings: []))
}

let data = WorldMap(countries: countries).encoded()
try data.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
print("\(countries.count) places (\(countries.filter(\.isDot).count) as dots), "
      + "\(pointsIn) points → \(pointsOut), \(data.count / 1024) KB")

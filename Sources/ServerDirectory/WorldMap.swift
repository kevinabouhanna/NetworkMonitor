import Foundation

/// The Equal Earth projection (Šavrič, Patterson and Jenny, 2018): every
/// country keeps its true area, so a big shaded country is big, and the world
/// still looks like the world. Its formulas are short enough to need no library.
public enum EqualEarth {
    static let a1 = 1.340264, a2 = -0.081106, a3 = 0.000893, a4 = 0.003796

    /// x and y for a longitude and latitude in degrees. y grows northwards.
    public static func project(longitude: Double, latitude: Double) -> (x: Double, y: Double) {
        let lambda = longitude * .pi / 180
        let theta = asin(sqrt(3) / 2 * sin(latitude * .pi / 180))
        let t2 = theta * theta, t6 = t2 * t2 * t2
        let x = 2 * sqrt(3) * lambda * cos(theta)
            / (3 * (9 * a4 * t6 * t2 + 7 * a3 * t6 + 3 * a2 * t2 + a1))
        let y = theta * (a1 + a2 * t2 + t6 * (a3 + a4 * t2))
        return (x, y)
    }

    /// The projection's edges: x at ±180° on the equator, y at the poles.
    public static let maxX = project(longitude: 180, latitude: 0).x
    public static let maxY = project(longitude: 0, latitude: 90).y
}

/// Every country's outline, projected and simplified once by `MapDataBuilder`
/// from Natural Earth's public-domain 1:10m data, for the Connections map.
///
/// Layout, little-endian:
///
///     0    "NMWM"           magic
///     4    UInt16           format version, 1
///     6    UInt16           reserved
///     8    UInt32           countries
///     then, per country:
///          2 × UInt8        ISO 3166-1 alpha-2 code, or two spaces for land
///                           with none (disputed areas, so the map has no holes)
///          2 × Int16        where its name or dot goes
///          UInt16           rings
///          per ring: UInt32 points, then points × 2 × Int16
///
/// Coordinates are Equal Earth x and y scaled so ±`EqualEarth.maxX` is
/// ±32767, the same scale for both, so shapes keep their proportions. A
/// country with no rings is a dot: a place too small for an outline at this
/// scale, or one Natural Earth draws inside another country, such as Réunion.
public struct WorldMap {

    public struct Point: Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Country {
        /// Empty for land no code covers.
        public let code: String
        public let label: Point
        public let rings: [[Point]]

        public init(code: String, label: Point, rings: [[Point]]) {
            self.code = code
            self.label = label
            self.rings = rings
        }

        public var isDot: Bool { rings.isEmpty }
    }

    static let magic: [UInt8] = Array("NMWM".utf8)
    static let version: UInt16 = 1
    static let scale = 32767 / EqualEarth.maxX

    public enum ReadError: Error, Equatable {
        case notAWorldMap
        case unsupportedVersion(UInt16)
        case truncated
    }

    public let countries: [Country]

    public init(countries: [Country]) {
        self.countries = countries
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        var reader = Reader(data: data)
        guard (try? reader.bytes(4)) == Self.magic else { throw ReadError.notAWorldMap }
        let version: UInt16 = try reader.integer()
        guard version == Self.version else { throw ReadError.unsupportedVersion(version) }
        let _: UInt16 = try reader.integer()
        let count: UInt32 = try reader.integer()
        var countries: [Country] = []
        countries.reserveCapacity(Int(count))
        for _ in 0..<count {
            let code = String(decoding: try reader.bytes(2), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            let label = try reader.point()
            let ringCount: UInt16 = try reader.integer()
            var rings: [[Point]] = []
            for _ in 0..<ringCount {
                let points: UInt32 = try reader.integer()
                var ring: [Point] = []
                ring.reserveCapacity(Int(points))
                for _ in 0..<points { ring.append(try reader.point()) }
                rings.append(ring)
            }
            countries.append(Country(code: code, label: label, rings: rings))
        }
        self.countries = countries
    }

    public func encoded() -> Data {
        var out = Data(Self.magic)
        out.append(littleEndian: Self.version)
        out.append(littleEndian: UInt16(0))
        out.append(littleEndian: UInt32(countries.count))
        for country in countries {
            let code = Array((country.code.isEmpty ? "  " : country.code).utf8.prefix(2))
            out.append(contentsOf: code + Array(repeating: UInt8(ascii: " "), count: 2 - code.count))
            out.append(point: country.label)
            out.append(littleEndian: UInt16(country.rings.count))
            for ring in country.rings {
                out.append(littleEndian: UInt32(ring.count))
                for point in ring { out.append(point: point) }
            }
        }
        return out
    }

    /// True when `point` is inside the outline, by the even-odd rule, so a
    /// lake is not its country.
    public static func contains(_ point: Point, rings: [[Point]]) -> Bool {
        var inside = false
        for ring in rings {
            var previous = ring.last ?? point
            for current in ring {
                if (current.y > point.y) != (previous.y > point.y),
                   point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
                    inside.toggle()
                }
                previous = current
            }
        }
        return inside
    }

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard offset + count <= data.count else { throw ReadError.truncated }
            defer { offset += count }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + count])
        }

        mutating func integer<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { throw ReadError.truncated }
            defer { offset += size }
            return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }

        mutating func point() throws -> Point {
            let x: Int16 = try integer(), y: Int16 = try integer()
            return Point(x: Double(x) / WorldMap.scale, y: Double(y) / WorldMap.scale)
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(point: WorldMap.Point) {
        func quantize(_ value: Double) -> Int16 {
            Int16(Swift.max(-32767, Swift.min(32767, (value * WorldMap.scale).rounded())))
        }
        append(littleEndian: quantize(point.x))
        append(littleEndian: quantize(point.y))
    }
}

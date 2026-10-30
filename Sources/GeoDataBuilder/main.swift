import CryptoKit
import Foundation
import ServerDirectory

// Converts DB-IP's free CSV databases into the files ServerDirectory reads,
// then checks every row against what was written. Run through
// Scripts/geodata.sh, which downloads them first:
//
//   GeoDataBuilder <dbip-country-lite.csv> <dbip-asn-lite.csv> <output directory>
//
// Country rows are `start,end,CC`, where `ZZ` means nowhere. Owner rows are
// `start,end,ASN,"Registered name"`, the name quoted when it contains a comma.
//
// And packages a converted month for the monthly refresh (#121): each table
// compressed, and a manifest of them signed with the Ed25519 key in
// GEODATA_SIGNING_KEY (the raw 32 bytes, base64), which the app checks
// against its public half before using anything:
//
//   GeoDataBuilder package <converted directory> <output directory>

let arguments = CommandLine.arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

if arguments.count >= 2, arguments[1] == "package" {
    guard arguments.count == 4 else { fail("usage: GeoDataBuilder package <converted directory> <output directory>") }
    let source = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
    guard let month = GeoData.month(in: source) else { fail("no MONTH in \(source.path)") }
    guard let encodedKey = ProcessInfo.processInfo.environment["GEODATA_SIGNING_KEY"],
          let keyData = Data(base64Encoded: encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else { fail("GEODATA_SIGNING_KEY is missing or isn't an Ed25519 key") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    var files: [GeoDataManifest.File] = []
    for name in GeoData.tables {
        let data = try Data(contentsOf: source.appendingPathComponent(name))
        _ = try RangeTable(data: data)
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        let asset = name + ".lzfse"
        try compressed.write(to: output.appendingPathComponent(asset), options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        files.append(GeoDataManifest.File(name: name, asset: asset, size: data.count, sha256: digest))
        print("\(name): \(data.count / 1024) KB, \(compressed.count / 1024) KB compressed")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifest = try encoder.encode(GeoDataManifest(month: month, files: files))
    try manifest.write(to: output.appendingPathComponent(GeoDataManifest.fileName), options: .atomic)
    let signature = try key.signature(for: manifest)
    try Data(signature.base64EncodedString().utf8)
        .write(to: output.appendingPathComponent(GeoDataManifest.signatureName), options: .atomic)
    print("\(month), signed with \(key.publicKey.rawRepresentation.base64EncodedString())")
    exit(0)
}

guard arguments.count == 4 else {
    FileHandle.standardError.write(Data(
        "usage: GeoDataBuilder <country.csv> <asn.csv> <output directory>\n".utf8))
    exit(2)
}

typealias Row = (start: IPAddress, end: IPAddress, label: String?)

/// Splits one CSV line, honouring double quotes and `""` inside them.
func fields(_ line: Substring) -> [String] {
    var fields: [String] = []
    var current = ""
    var quoted = false
    var iterator = line.makeIterator()
    while let character = iterator.next() {
        switch character {
        case "\"" where quoted:
            // `""` inside quotes is a literal quote; a lone one closes them.
            var lookahead = iterator
            if lookahead.next() == "\"" {
                current.append("\"")
                iterator = lookahead
            } else {
                quoted = false
            }
        case "\"":
            quoted = true
        case "," where !quoted:
            fields.append(current)
            current = ""
        default:
            current.append(character)
        }
    }
    fields.append(current)
    return fields
}

func rows(from source: String, label: ([String]) -> String?) throws -> [Row] {
    let text = try String(contentsOfFile: source, encoding: .utf8)
    var rows: [Row] = []
    for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
        let row = fields(line)
        guard row.count >= 3, let start = IPAddress(row[0]), let end = IPAddress(row[1]) else {
            FileHandle.standardError.write(Data("skipped: \(line)\n".utf8))
            continue
        }
        rows.append((start, end, label(row)))
    }
    return rows
}

/// Every row's first and last address must read back its own label.
///
/// IPv6 is keyed on whole /64s, so only rows that start and end on /64
/// boundaries can be held to that. The rest, a few hundred, are split inside
/// a /64, and RangeTable documents what they read back.
func verify(_ table: RangeTable, against rows: [Row]) -> (checked: Int, skipped: Int, wrong: [String]) {
    var checked = 0, skipped = 0
    var wrong: [String] = []
    for row in rows {
        if case .v6(let start) = row.start, case .v6(let end) = row.end,
           start.low != 0 || end.low != .max {
            skipped += 1
            continue
        }
        checked += 1
        for address in [row.start, row.end] where table.label(for: address) != row.label {
            wrong.append("\(address): expected \(row.label ?? "nothing"), "
                         + "read \(table.label(for: address) ?? "nothing")")
        }
    }
    return (checked, skipped, wrong)
}

let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sources: [(name: String, rows: [Row])] = [
    ("countries.bin", try rows(from: arguments[1]) { row in
        row[2] == "ZZ" || row[2].isEmpty ? nil : row[2]
    }),
    ("owners.bin", try rows(from: arguments[2]) { row in
        guard row.count >= 4, let asn = UInt32(row[2]), asn != 0 else { return nil }
        return "\(asn)\t\(row[3])"
    }),
]

var failed = false
for (name, rows) in sources {
    var writer = RangeTableWriter()
    for row in rows { try writer.add(from: row.start, to: row.end, label: row.label) }
    let data = writer.encoded()
    let table = try RangeTable(data: data)
    let check = verify(table, against: rows)
    print("\(name): \(rows.count) rows → \(table.ipv4Count) IPv4 + \(table.ipv6Count) IPv6 ranges, "
          + "\(table.labelCount) labels, \(data.count / 1024) KB; "
          + "\(check.checked) rows read back, \(check.skipped) split inside a /64")
    if check.wrong.isEmpty {
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
    } else {
        failed = true
        print("  \(check.wrong.count) wrong, so \(name) was not written. First few:")
        for line in check.wrong.prefix(5) { print("  \(line)") }
    }
}
exit(failed ? 1 : 0)

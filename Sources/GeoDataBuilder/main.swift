import Foundation
import ServerDirectory

// Converts DB-IP's free CSV databases into the files ServerDirectory reads.
// Run through Scripts/geodata.sh, which downloads them first:
//
//   GeoDataBuilder <dbip-country-lite.csv> <dbip-asn-lite.csv> <output directory>
//
// Country rows are `start,end,CC`, where `ZZ` means nowhere. Owner rows are
// `start,end,ASN,"Registered name"`, the name quoted when it contains a comma.

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data(
        "usage: GeoDataBuilder <country.csv> <asn.csv> <output directory>\n".utf8))
    exit(2)
}

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

func build(from source: String, label: ([String]) -> String?) throws -> (Data, rows: Int) {
    let text = try String(contentsOfFile: source, encoding: .utf8)
    var writer = RangeTableWriter()
    var rows = 0
    for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
        let row = fields(line)
        guard row.count >= 3, let start = IPAddress(row[0]), let end = IPAddress(row[1]) else {
            FileHandle.standardError.write(Data("skipped: \(line)\n".utf8))
            continue
        }
        try writer.add(from: start, to: end, label: label(row))
        rows += 1
    }
    return (writer.encoded(), rows)
}

let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let (countries, countryRows) = try build(from: arguments[1]) { row in
    row[2] == "ZZ" || row[2].isEmpty ? nil : row[2]
}
let (owners, ownerRows) = try build(from: arguments[2]) { row in
    guard row.count >= 4, let asn = UInt32(row[2]), asn != 0 else { return nil }
    return "\(asn)\t\(row[3])"
}

for (name, data, rows) in [("countries.bin", countries, countryRows), ("owners.bin", owners, ownerRows)] {
    try data.write(to: output.appendingPathComponent(name), options: .atomic)
    let table = try RangeTable(data: data)
    print("\(name): \(rows) rows → \(table.ipv4Count) IPv4 + \(table.ipv6Count) IPv6 ranges, "
          + "\(table.labelCount) labels, \(data.count / 1024) KB")
}

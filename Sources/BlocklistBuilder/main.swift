import CryptoKit
import FirewallPolicy
import Foundation

// Builds the ad, tracker and malware lists (#176) from their public sources,
// and packages them for the weekly refresh:
//
//   BlocklistBuilder build <output directory> [version]
//   BlocklistBuilder package <built directory> <output directory>
//
// `build` writes each topic's table, a VERSION (the date, UTC) and SOURCES.md.
// A list that comes back far smaller than it should is refused rather than
// published: a bad download would otherwise unblock everything it held.
// `package` compresses the tables and signs a manifest with the Ed25519 key in
// GEODATA_SIGNING_KEY, the one the country data is signed with (#121), whose
// public half is in the app.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Far below what each list holds, and far above an error page.
let minimumNames: [BlocklistTopic: Int] = [.ads: 20_000, .malware: 100]

func download(_ url: URL) -> String {
    var result: Result<String, Error> = .failure(URLError(.unknown))
    let done = DispatchSemaphore(value: 0)
    var request = URLRequest(url: url, timeoutInterval: 120)
    request.setValue("NetworkMonitor-BlocklistBuilder", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { done.signal() }
        if let error { result = .failure(error); return }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data, let text = String(data: data, encoding: .utf8)
        else { result = .failure(URLError(.badServerResponse)); return }
        result = .success(text)
    }.resume()
    done.wait()
    switch result {
    case .success(let text): return text
    case .failure(let error): fail("\(url): \(error)")
    }
}

func today() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    fail("usage: BlocklistBuilder build <output directory> [version] | package <built directory> <output directory>")
}

switch arguments[1] {
case "build":
    let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let version = arguments.count >= 4 ? arguments[3] : today()
    guard Blocklists.isVersion(version) else { fail("version must be yyyy-MM-dd: \(version)") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var sources = "# Where these lists come from\n\nBuilt \(version) by `BlocklistBuilder` for NetworkMonitor (#176).\n\n"
    sources += "| Topic | Source | Licence | Names |\n|---|---|---|---|\n"
    for topic in BlocklistTopic.allCases {
        let names = BlocklistParser.names(in: download(topic.sourceURL))
        let table = BlocklistTable(names: names)
        guard table.count >= minimumNames[topic, default: 1] else {
            fail("\(topic.rawValue): only \(table.count) names from \(topic.sourceURL); refusing to publish")
        }
        try table.encoded().write(to: output.appendingPathComponent(topic.fileName), options: .atomic)
        sources += "| \(topic.title) | [\(topic.source)](\(topic.sourceURL)) | \(topic.licence) | \(table.count) |\n"
        print("\(topic.rawValue): \(table.count) names")
    }
    try Data((version + "\n").utf8).write(to: output.appendingPathComponent(Blocklists.versionFile), options: .atomic)
    try Data(sources.utf8).write(to: output.appendingPathComponent("SOURCES.md"), options: .atomic)
    guard Blocklists(directory: output) != nil else { fail("the lists written don't read back") }

case "package":
    guard arguments.count == 4 else { fail("usage: BlocklistBuilder package <built directory> <output directory>") }
    let source = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
    guard let version = Blocklists.version(in: source), Blocklists(directory: source) != nil else {
        fail("no complete lists in \(source.path)")
    }
    guard let encodedKey = ProcessInfo.processInfo.environment["GEODATA_SIGNING_KEY"],
          let keyData = Data(base64Encoded: encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else { fail("GEODATA_SIGNING_KEY is missing or isn't an Ed25519 key") }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    var files: [BlocklistManifest.File] = []
    for topic in BlocklistTopic.allCases {
        let data = try Data(contentsOf: source.appendingPathComponent(topic.fileName))
        let compressed = try (data as NSData).compressed(using: .lzfse) as Data
        let asset = topic.fileName + ".lzfse"
        try compressed.write(to: output.appendingPathComponent(asset), options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        files.append(BlocklistManifest.File(name: topic.fileName, asset: asset, size: data.count, sha256: digest))
        print("\(topic.fileName): \(data.count / 1024) KB, \(compressed.count / 1024) KB compressed")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifest = try encoder.encode(BlocklistManifest(version: version, files: files))
    try manifest.write(to: output.appendingPathComponent(BlocklistManifest.fileName), options: .atomic)
    let signature = try key.signature(for: manifest)
    try Data(signature.base64EncodedString().utf8)
        .write(to: output.appendingPathComponent(BlocklistManifest.signatureName), options: .atomic)
    try FileManager.default.copyItem(at: source.appendingPathComponent("SOURCES.md"),
                                     to: output.appendingPathComponent("SOURCES.md"))
    print("\(version), signed with \(key.publicKey.rawRepresentation.base64EncodedString())")

default:
    fail("unknown command \(arguments[1])")
}

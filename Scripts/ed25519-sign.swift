import CryptoKit
import Foundation

// Signs a file with the Ed25519 key in SPARKLE_ED_KEY (the raw 32 bytes,
// base64), as Sparkle's own sign_update does, and prints the signature in
// base64 (#132). With --public, prints the key's public half instead, so the
// release can check it is the one the app carries.
//
//   swift Scripts/ed25519-sign.swift <file>
//   swift Scripts/ed25519-sign.swift --public

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let encoded = ProcessInfo.processInfo.environment["SPARKLE_ED_KEY"],
      let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
else { fail("SPARKLE_ED_KEY is missing or isn't an Ed25519 key") }

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--public" {
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else if let path = arguments.first, let data = FileManager.default.contents(atPath: path) {
    print(try key.signature(for: data).base64EncodedString())
} else {
    fail("usage: ed25519-sign.swift <file> | --public")
}

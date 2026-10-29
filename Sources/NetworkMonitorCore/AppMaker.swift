import Foundation
import Security

/// Who made an app, read from its code signature.
///
/// A Developer ID certificate names the company that signed the app ("Developer
/// ID Application: Microsoft Corporation (UBF8T346G9)"), and Apple signs its own
/// software as "macOS Software Signing" ("Software Signing" before macOS 27).
/// The Connections window shows it under the app, and points out when an app
/// talks to companies other than its maker.
///
/// Reading a signature's certificates doesn't check it, so it's quick, needs
/// no permission and makes no network request.
public enum AppMaker {

    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    /// The maker of the bundle at `path`, or nil when its signature doesn't say:
    /// an ad-hoc or self-signed app, or a Mac App Store one, whose certificate
    /// is Apple's whoever wrote it.
    public static func name(ofBundleAt path: String) -> String? {
        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var name: String?
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
           let code {
            var information: CFDictionary?
            if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                             &information) == errSecSuccess,
               let dictionary = information as? [String: Any],
               let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
               let leaf = certificates.first,
               let summary = SecCertificateCopySubjectSummary(leaf) as String? {
                name = Self.name(fromCertificateSummary: summary)
            }
        }

        lock.lock()
        cache[path] = name
        lock.unlock()
        return name
    }

    /// The maker named by a signing certificate's subject.
    public static func name(fromCertificateSummary summary: String) -> String? {
        if summary.hasSuffix("Software Signing") { return "Apple" }
        let prefix = "Developer ID Application: "
        guard summary.hasPrefix(prefix) else { return nil }
        var name = String(summary.dropFirst(prefix.count))
        // The team ID in brackets at the end, such as " (UBF8T346G9)".
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
        }
        // Some register in capitals: "SLACK TECHNOLOGIES L.L.C.".
        if name == name.uppercased(), name.contains(where: \.isLetter) {
            name = name.capitalized
        }
        return name.isEmpty ? nil : name
    }
}

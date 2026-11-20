import FirewallPolicy
import Foundation
import Security

// What Enhanced ad blocking does to a page (#683, a step of #256): a site's
// HTML page is given its hiding rules as a stylesheet and its scriptlets as a
// script, placed before anything of the page's own; every other reply, and any
// page it can't read for certain, passes on exactly as the server sent it.

/// What a page on a site gets: its hiding selectors and scriptlets.
public struct PageAdditions: Equatable {
    public var selectors: [String]
    public var scriptlets: [Scriptlet]

    public init(selectors: [String], scriptlets: [Scriptlet]) {
        self.selectors = selectors
        self.scriptlets = scriptlets
    }

    public init(_ forPage: PageRules.ForPage) {
        self.init(selectors: forPage.selectors, scriptlets: forPage.scriptlets)
    }

    public var isEmpty: Bool { selectors.isEmpty && scriptlets.isEmpty }
}

public enum PageRewriter {

    /// Why a reply passed on untouched, for the log; nil when it was changed.
    public enum Untouched: Equatable {
        case notAPage
        case nothingToAdd
        case cantRead(String)
    }

    /// The reply to send on: the page with its additions, or the reply's own
    /// bytes, unchanged, whenever anything isn't as expected. `response` is
    /// the whole reply as the server sent it, head and body; `requestMethod`
    /// is the request's.
    public static func rewrite(response: Data, requestMethod: String?, additions: PageAdditions,
                               nonce: String = randomNonce()) -> (bytes: Data, untouched: Untouched?) {
        do {
            guard let (head, bodyStart) = try HTTPHead.parse(response) else {
                return (response, .cantRead("an incomplete head"))
            }
            guard isPage(head, requestMethod: requestMethod) else { return (response, .notAPage) }
            guard !additions.isEmpty else { return (response, .nothingToAdd) }
            let rawBody = response[(response.startIndex + bodyStart)...]
            let body: Data
            switch try BodyFraming.forResponse(head, requestMethod: requestMethod) {
            case .none:
                return (response, .notAPage)
            case .length(let length):
                guard rawBody.count == length else { return (response, .cantRead("a body of the wrong length")) }
                body = Data(rawBody)
            case .chunked:
                guard let (content, used) = try ChunkedBody.decode(Data(rawBody)), used == rawBody.count else {
                    return (response, .cantRead("a chunked body that doesn't end where the reply does"))
                }
                body = content
            case .untilClose:
                body = Data(rawBody)
            }
            let html = try BodyCoding.decode(body, encoding: head.value("Content-Encoding"))
            guard let page = inject(additions, into: html, nonce: nonce) else {
                return (response, .cantRead("no place in the page to add to"))
            }
            var newHead = head
            newHead.remove("Content-Encoding")
            newHead.remove("Transfer-Encoding")
            // What described the bytes as sent no longer does: their digests,
            // their tag (or a later visit could be told the old page is still
            // good), byte ranges.
            for stale in ["Content-MD5", "Digest", "Content-Digest", "Repr-Digest", "ETag", "Accept-Ranges"] {
                newHead.remove(stale)
            }
            newHead.set("Content-Length", String(page.count))
            for (index, header) in newHead.headers.enumerated()
            where header.name.caseInsensitiveCompare("Content-Security-Policy") == .orderedSame {
                newHead.headers[index].value = allowing(nonce: nonce, in: header.value)
            }
            return (newHead.bytes + page, nil)
        } catch {
            return (response, .cantRead(Self.kind(of: error)))
        }
    }

    /// What went wrong, by its kind alone: an error may hold text from the
    /// message (a header, a line of the page), and this reaches the log.
    static func kind(of error: Error) -> String {
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
        if mirror.displayStyle == .enum { return "\(error)" }
        return String(describing: type(of: error))
    }

    /// An HTML page worth adding to: a whole page (200 or 203, never a part
    /// of one), in HTML (not XHTML, whose parser would refuse our script's
    /// `<` and `&&`), not in UTF-16 (where bytes added in ASCII would break it).
    static func isPage(_ head: HTTPHead, requestMethod: String?) -> Bool {
        guard let status = head.status, status == 200 || status == 203, requestMethod != "HEAD",
              head.value("Content-Range") == nil,
              let type = head.value("Content-Type")?.lowercased(), type.hasPrefix("text/html") else { return false }
        return !type.contains("utf-16")
    }

    /// The page with the stylesheet and script placed first in its head (or
    /// body, or html), or nil when it has none of them. Every byte of the
    /// page stays as it was; only these are added.
    public static func inject(_ additions: PageAdditions, into page: Data, nonce: String) -> Data? {
        let bytes = [UInt8](page)
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { return nil }   // UTF-16
        guard let at = insertionPoint(bytes) else { return nil }
        var added = ""
        let selectors = additions.selectors.filter(isSafeSelector)
        if !selectors.isEmpty {
            // A rule each, so one a browser can't read never takes others with
            // it; and only selectors whose brackets and quotes close, so none
            // can swallow the rules after it.
            let css = selectors.map { $0 + "{display:none!important}" }.joined(separator: "\n")
            added += "<style nonce=\"\(nonce)\">\n" + css.replacingOccurrences(of: "</", with: "<\\/") + "\n</style>"
        }
        // A script with `<!--` or `<script` in it could keep the browser from
        // ending it where it ends: left out, as everything else of the page
        // goes on as it is.
        if let script = ScriptletCode.script(for: additions.scriptlets),
           !script.lowercased().contains("<!--"), !script.lowercased().contains("<script") {
            added += "<script nonce=\"\(nonce)\">" + script.replacingOccurrences(of: "</", with: "<\\/") + "</script>"
        }
        guard !added.isEmpty else { return nil }
        return Data(bytes[..<at]) + Data(added.utf8) + Data(bytes[at...])
    }

    /// A selector that can stand as its own rule: brackets, parentheses and
    /// quotes that close, no braces, no comment.
    static func isSafeSelector(_ selector: String) -> Bool {
        guard !selector.contains("{"), !selector.contains("}"), !selector.contains("/*"), !selector.contains("<") else {
            return false
        }
        var stack: [Character] = []
        var quote: Character?
        var escaped = false
        for character in selector {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let open = quote { if character == open { quote = nil }; continue }
            switch character {
            case "\"", "'": quote = character
            case "[", "(": stack.append(character)
            case "]": guard stack.popLast() == "[" else { return false }
            case ")": guard stack.popLast() == "(" else { return false }
            default: break
            }
        }
        return stack.isEmpty && quote == nil && !escaped
    }

    /// Just after the opening `<head …>`, else `<body …>`, else `<html …>`.
    /// A `<head` (or `<html`) counts only before the page's first script or
    /// body, so one written inside a script's text is never taken for it.
    static func insertionPoint(_ bytes: [UInt8]) -> Int? {
        // The first part of a page is enough to find its head.
        let window = Array(bytes.prefix(256 * 1024)).map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 }
        let firstScript = firstIndex(of: Array("<script".utf8), in: window, from: 0) ?? window.count
        let firstBody = firstIndex(of: Array("<body".utf8), in: window, from: 0) ?? window.count
        for tag in ["<head", "<body", "<html"] {
            let needle = Array(tag.utf8)
            let limit = tag == "<body" ? window.count : min(firstScript, firstBody)
            var index = 0
            while let found = firstIndex(of: needle, in: window, from: index), found < limit {
                let after = found + needle.count
                // `<header>` isn't `<head>`.
                guard after < window.count else { break }
                let next = window[after]
                if next == UInt8(ascii: ">") || next == UInt8(ascii: " ") || next == UInt8(ascii: "\t")
                    || next == UInt8(ascii: "\n") || next == UInt8(ascii: "\r") || next == UInt8(ascii: "/") {
                    guard let close = window[after...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
                    return close + 1
                }
                index = after
            }
        }
        return nil
    }

    static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0] && Array(haystack[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    /// A Content-Security-Policy that lets our stylesheet and script run: the
    /// nonce added to `script-src` and `style-src` (or `default-src` where
    /// those aren't given), except where `'unsafe-inline'` already allows
    /// them, as a nonce would switch that off for the page's own.
    public static func allowing(nonce: String, in policy: String) -> String {
        var directives = policy.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func name(_ directive: String) -> String { directive.split(separator: " ").first.map { $0.lowercased() } ?? "" }
        // The -elem directives, where a policy has them, are what a browser
        // checks a <script> or <style> against first: the nonce goes there too.
        for wanted in ["script-src", "style-src", "script-src-elem", "style-src-elem"] {
            let own = directives.firstIndex { name($0) == wanted }
            if wanted.hasSuffix("-elem") && own == nil { continue }
            let target = own ?? directives.firstIndex { name($0) == "default-src" }
            guard let index = target else { continue }
            let sources = directives[index].lowercased()
            if sources.contains("'unsafe-inline'") && !sources.contains("'nonce-") && !sources.contains("'sha") { continue }
            if name(directives[index]) == "default-src" {
                // Its own directive, so default-src stays as it was for the rest.
                directives.append(wanted + directives[index].dropFirst("default-src".count) + " 'nonce-\(nonce)'")
            } else {
                directives[index] += " 'nonce-\(nonce)'"
            }
        }
        return directives.joined(separator: "; ")
    }

    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}

/// The real server's certificate, checked as a browser checks it: refused
/// unless macOS trusts it for that name. Enhanced ad blocking never stands in
/// for a site whose own certificate the person's browser would refuse.
public enum ServerTrust {
    /// A handshake's own trust, with what the site stapled to it, checked
    /// for `host` as a browser would (and against `anchors` alone in tests).
    public static func isTrusted(_ trust: SecTrust, host: String, anchors: [SecCertificate]? = nil) -> Bool {
        guard SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess else { return false }
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        return SecTrustEvaluateWithError(trust, nil)
    }

    public static func isTrusted(_ chain: [SecCertificate], host: String, anchors: [SecCertificate]? = nil,
                                 at date: Date = Date()) -> Bool {
        guard !chain.isEmpty else { return false }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, host as CFString),
                                             &trust) == errSecSuccess, let trust else { return false }
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        SecTrustSetVerifyDate(trust, date as CFDate)
        return SecTrustEvaluateWithError(trust, nil)
    }
}

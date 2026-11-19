import CryptoKit
import FirewallPolicy
import Foundation
import JavaScriptCore
import PageRewriter
import Security
import SiteCertificates
import SwiftASN1
import X509

/// The page rewriter (#683): a page given its site's hiding and scriptlets,
/// everything else, and anything it can't read for certain, untouched.
func runPageRewriterTests() {
    let page = """
        <!doctype html>
        <html lang="en"><HEAD data-x="1"><title>News</title></HEAD>
        <body><header>Top</header><div class="ad-banner">Buy</div><p>Story</p></body></html>
        """
    let additions = PageAdditions(selectors: [".ad-banner", "#sponsor"],
                                  scriptlets: [Scriptlet(name: "set-constant", arguments: ["adsAllowed", "false"])])
    let nonce = "TESTNONCE"

    func gzip(_ data: Data) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", "-n"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try? process.run()
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return result
    }

    func response(_ headers: [String], _ body: Data, status: String = "HTTP/1.1 200 OK") -> Data {
        Data((([status] + headers).joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    /// The page as it should come out: the same bytes, with ours placed
    /// after `<HEAD data-x="1">`.
    let expectedPage: Data = {
        let added = "<style nonce=\"\(nonce)\">\n.ad-banner{display:none!important}\n#sponsor{display:none!important}\n</style>"
            + "<script nonce=\"\(nonce)\">" + ScriptletCode.script(for: additions.scriptlets)! + "</script>"
        let marker = "<HEAD data-x=\"1\">"
        return Data(page.replacingOccurrences(of: marker, with: marker + added).utf8)
    }()

    Check.suite("Page rewriter — a page gets its site's additions (#683)") {

        Check.test("a gzipped page gets its stylesheet and script, and nothing else changes") {
            let body = gzip(Data(page.utf8))
            let reply = response(["Content-Type: text/html; charset=utf-8", "Content-Encoding: gzip",
                                  "Content-Length: \(body.count)", "Cache-Control: max-age=60",
                                  "Content-Security-Policy: default-src 'self'; img-src *"], body)
            let (bytes, untouched) = PageRewriter.rewrite(response: reply, requestMethod: "GET", additions: additions,
                                                          nonce: nonce)
            Check.expectNil(untouched)
            // The length where it was, the coding gone, the policy allowing ours.
            let expected = response(["Content-Type: text/html; charset=utf-8", "Content-Length: \(expectedPage.count)",
                                     "Cache-Control: max-age=60",
                                     "Content-Security-Policy: default-src 'self'; img-src *; "
                                        + "script-src 'self' 'nonce-\(nonce)'; style-src 'self' 'nonce-\(nonce)'"],
                                    expectedPage)
            Check.expectEqual(bytes, expected)
        }

        Check.test("a chunked page, and one that ends when the server closes") {
            let html = Data(page.utf8)
            var chunked = Data()
            for part in [html.prefix(50), html.dropFirst(50)] {
                chunked += Data(String(part.count, radix: 16).utf8) + Data("\r\n".utf8) + part + Data("\r\n".utf8)
            }
            chunked += Data("0\r\n\r\n".utf8)
            let reply = response(["Content-Type: text/html", "Transfer-Encoding: chunked"], chunked)
            let (bytes, untouched) = PageRewriter.rewrite(response: reply, requestMethod: "GET", additions: additions,
                                                          nonce: nonce)
            Check.expectNil(untouched)
            Check.expectEqual(bytes, response(["Content-Type: text/html", "Content-Length: \(expectedPage.count)"],
                                              expectedPage))
            let open = response(["Content-Type: text/html"], html)
            Check.expectEqual(PageRewriter.rewrite(response: open, requestMethod: "GET", additions: additions,
                                                   nonce: nonce).bytes,
                              response(["Content-Type: text/html", "Content-Length: \(expectedPage.count)"], expectedPage))
        }

        Check.test("a page's own inline code keeps working: 'unsafe-inline' left alone") {
            Check.expectEqual(PageRewriter.allowing(nonce: "n", in: "script-src 'self' 'unsafe-inline'"),
                              "script-src 'self' 'unsafe-inline'")
            Check.expectEqual(PageRewriter.allowing(nonce: "n", in: "script-src 'nonce-abc' 'strict-dynamic'"),
                              "script-src 'nonce-abc' 'strict-dynamic' 'nonce-n'")
        }
    }

    Check.suite("Page rewriter — anything else passes on untouched (#683)") {

        Check.test("what isn't a page, or has nothing to add") {
            let image = response(["Content-Type: image/png", "Content-Length: 4"], Data([1, 2, 3, 4]))
            let imageResult = PageRewriter.rewrite(response: image, requestMethod: "GET", additions: additions)
            Check.expectEqual(imageResult.bytes, image)
            Check.expectEqual(imageResult.untouched, .notAPage)
            let html = response(["Content-Type: text/html", "Content-Length: \(page.utf8.count)"], Data(page.utf8))
            Check.expectEqual(PageRewriter.rewrite(response: html, requestMethod: "HEAD", additions: additions).untouched,
                              .notAPage)
            Check.expectEqual(PageRewriter.rewrite(response: html, requestMethod: "GET",
                                                   additions: PageAdditions(selectors: [], scriptlets: [])).bytes, html)
            let redirect = response(["Location: /x", "Content-Type: text/html", "Content-Length: 0"], Data(),
                                    status: "HTTP/1.1 302 Found")
            Check.expectEqual(PageRewriter.rewrite(response: redirect, requestMethod: "GET", additions: additions).bytes,
                              redirect)
        }

        // Each stage broken on purpose: the reply goes on as it came.
        Check.test("a broken reply, at every stage, passes on as it came") {
            let gz = gzip(Data(page.utf8))
            let broken: [(String, Data)] = [
                ("a head cut short", Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n".utf8)),
                ("a folded header", response(["Content-Type: text/html", " folded", "Content-Length: 1"], Data("x".utf8))),
                ("a body shorter than it says", response(["Content-Type: text/html", "Content-Length: 9999"], Data(page.utf8))),
                ("two lengths", response(["Content-Type: text/html", "Content-Length: 3", "Content-Length: 4"], Data("abcd".utf8))),
                ("an unknown encoding", response(["Content-Type: text/html", "Content-Encoding: zstd",
                                                  "Content-Length: 4"], Data("abcd".utf8))),
                ("a gzip that isn't", response(["Content-Type: text/html", "Content-Encoding: gzip",
                                                "Content-Length: 4"], Data("abcd".utf8))),
                ("a gzip cut short", response(["Content-Type: text/html", "Content-Encoding: gzip",
                                               "Content-Length: \(gz.count - 9)"], gz.dropLast(9))),
                ("a chunk cut short", response(["Content-Type: text/html", "Transfer-Encoding: chunked"],
                                               Data("ff\r\nabc".utf8))),
                ("another transfer coding", response(["Content-Type: text/html", "Transfer-Encoding: gzip, chunked"],
                                                     Data("0\r\n\r\n".utf8))),
                ("no head, body or html", response(["Content-Type: text/html", "Content-Length: 5"], Data("hello".utf8))),
                ("UTF-16", response(["Content-Type: text/html; charset=UTF-16", "Content-Length: 4"], Data([0xFF, 0xFE, 0x3C, 0])))
            ]
            for (what, reply) in broken {
                let (bytes, untouched) = PageRewriter.rewrite(response: reply, requestMethod: "GET", additions: additions)
                Check.expectEqual(bytes, reply, what)
                Check.expectNotNil(untouched, what)
            }
        }

        Check.test("a decoded body past 32 MB stops decoding and passes on") {
            let big = gzip(Data(repeating: UInt8(ascii: "a"), count: 33 * 1024 * 1024))
            let reply = response(["Content-Type: text/html", "Content-Encoding: gzip", "Content-Length: \(big.count)"], big)
            Check.expectEqual(PageRewriter.rewrite(response: reply, requestMethod: "GET", additions: additions).bytes, reply)
        }
    }

    Check.suite("Page rewriter — the real server's certificate (#683)") {
        Check.test("a server whose certificate macOS doesn't trust is refused") {
            do {
                let authority = try CertificateAuthority.make(key: Certificate.PrivateKey(P256.Signing.PrivateKey()),
                                                              machine: "Somebody")
                let site = try SiteCertificateCache(authority: authority).certificate(for: "www.example.com")
                var serializer = DER.Serializer()
                try serializer.serialize(site)
                let leaf = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData)!
                let root = SecCertificateCreateWithData(nil, try authority.der() as CFData)!
                Check.expectFalse(ServerTrust.isTrusted([leaf], host: "www.example.com"), "a root macOS doesn't trust")
                Check.expectTrue(ServerTrust.isTrusted([leaf], host: "www.example.com", anchors: [root]), "with its root")
                Check.expectFalse(ServerTrust.isTrusted([leaf], host: "bank.example", anchors: [root]), "another name")
                Check.expectFalse(ServerTrust.isTrusted([], host: "www.example.com"), "no certificate")
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }
    }

    Check.suite("Page rewriter — the scriptlets' own code (#683)") {
        /// Runs a page's script in JavaScriptCore with a little of a page around it.
        func run(_ scriptlets: [Scriptlet], then check: String) -> JSValue? {
            let context = JSContext()!
            var failure: String?
            context.exceptionHandler = { _, value in failure = value?.toString() }
            context.evaluateScript("""
                var window = this; var document = {readyState: "complete", currentScript: null,
                  querySelectorAll: function(){ return []; }, documentElement: {}, addEventListener: function(){}};
                function MutationObserver(){ this.observe = function(){}; }
                var timers = []; window.setTimeout = function(f, t){ timers.push(t); return timers.length; };
                """)
            context.evaluateScript(ScriptletCode.script(for: scriptlets) ?? "")
            Check.expectNil(failure, "the script runs: \(failure ?? "")")
            return context.evaluateScript(check)
        }

        Check.test("every scriptlet is valid script, and runs") {
            for name in Set(Scriptlet.known.values) {
                _ = run([Scriptlet(name: name, arguments: ["a.b", "1"])], then: "1")
            }
        }

        Check.test("json-prune takes ad slots out of what the page reads") {
            let value = run([Scriptlet(name: "json-prune", arguments: ["playerResponse.adPlacements"])],
                            then: "JSON.stringify(JSON.parse('{\"playerResponse\":{\"adPlacements\":[1],\"video\":2}}'))")
            Check.expectEqual(value?.toString(), "{\"playerResponse\":{\"video\":2}}")
        }

        Check.test("set-constant, abort-on-property-read and no-setTimeout-if") {
            Check.expectEqual(run([Scriptlet(name: "set-constant", arguments: ["ads.enabled", "false"])],
                                  then: "window.ads.enabled = true; window.ads.enabled")?.toBool(), false)
            Check.expectEqual(run([Scriptlet(name: "abort-on-property-read", arguments: ["adsbygoogle"])],
                                  then: "var r; try { r = window.adsbygoogle; r = 'read'; } catch (e) { r = 'stopped'; } r")?
                                .toString(), "stopped")
            Check.expectEqual(run([Scriptlet(name: "no-setTimeout-if", arguments: ["adblock"])],
                                  then: "setTimeout('detect adblock', 5); setTimeout('other', 7); timers.join(',')")?
                                .toString(), "7")
        }
    }
}

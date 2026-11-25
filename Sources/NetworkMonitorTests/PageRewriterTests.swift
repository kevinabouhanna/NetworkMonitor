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

        Check.test("what described the bytes as sent is dropped: tag, digest, ranges") {
            let reply = response(["Content-Type: text/html", "ETag: \"abc\"", "Accept-Ranges: bytes",
                                  "Content-Length: \(page.utf8.count)"], Data(page.utf8))
            let (bytes, _) = PageRewriter.rewrite(response: reply, requestMethod: "GET", additions: additions, nonce: nonce)
            Check.expectEqual(bytes, response(["Content-Type: text/html", "Content-Length: \(expectedPage.count)"],
                                              expectedPage))
        }

        Check.test("our code goes in the page's head, never into a script that mentions one") {
            let noHead = "<html><body><script>w.document.write(\"<head><title>x</title></head>\")</script><p>Hi</p></body></html>"
            let out = PageRewriter.inject(additions, into: Data(noHead.utf8), nonce: nonce).map { String(decoding: $0, as: UTF8.self) }
            Check.expectTrue(out?.hasPrefix("<html><body><style") == true, "after <body>: \(out?.prefix(40) ?? "")")
        }

        Check.test("a selector whose brackets or quotes don't close is left out, never swallows others") {
            let risky = PageAdditions(selectors: ["div[data-x=\"a\"", ".ok", "a}body{color:red", "p:not(.x"], scriptlets: [])
            let out = PageRewriter.inject(risky, into: Data(page.utf8), nonce: nonce).map { String(decoding: $0, as: UTF8.self) } ?? ""
            Check.expectTrue(out.contains(".ok{display:none!important}"))
            Check.expectFalse(out.contains("div[data-x"))
            Check.expectFalse(out.contains("body{color"))
            Check.expectFalse(out.contains("p:not(.x"))
        }

        Check.test("a policy's -elem directives get the nonce too") {
            Check.expectEqual(PageRewriter.allowing(nonce: "n", in: "script-src 'self'; script-src-elem 'self' https://cdn.x"),
                              "script-src 'self' 'nonce-n'; script-src-elem 'self' https://cdn.x 'nonce-n'")
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
                ("UTF-16", response(["Content-Type: text/html; charset=UTF-16", "Content-Length: 4"], Data([0xFF, 0xFE, 0x3C, 0]))),
                ("a chunk size no reply could hold", response(["Content-Type: text/html", "Transfer-Encoding: chunked"],
                                                              Data("7fffffffffffffff\r\nabc".utf8))),
                ("a part of a page", response(["Content-Type: text/html", "Content-Range: bytes 0-99/500",
                                               "Content-Length: \(page.utf8.count)"], Data(page.utf8),
                                              status: "HTTP/1.1 206 Partial Content")),
                ("XHTML", response(["Content-Type: application/xhtml+xml", "Content-Length: \(page.utf8.count)"],
                                   Data(page.utf8)))
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

        Check.test("set-constant waits for an object the page hasn't made, never makes it") {
            Check.expectEqual(run([Scriptlet(name: "set-constant", arguments: ["adConfig.enabled", "false"])],
                                  then: "var before = (typeof window.adConfig); window.adConfig = {enabled: true, load: 1};"
                                        + " before + ',' + window.adConfig.enabled + ',' + window.adConfig.load")?.toString(),
                              "undefined,false,1")
        }

        Check.test("no-setTimeout-if with nothing to look for leaves timers alone; ! means not") {
            Check.expectEqual(run([Scriptlet(name: "no-setTimeout-if", arguments: [])],
                                  then: "setTimeout('a', 1); setTimeout('b', 2); timers.join(',')")?.toString(), "1,2")
            Check.expectEqual(run([Scriptlet(name: "no-setTimeout-if", arguments: ["!keep"])],
                                  then: "setTimeout('keep me', 1); setTimeout('drop', 2); timers.join(',')")?.toString(), "1")
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

        Check.test("where a body ends, however it's cut into pieces (#741)") {
            let chunked = Data("5\r\nhello\r\n1;x=y\r\n!\r\n0\r\nTrailer: a\r\n\r\n".utf8)
            for size in 1...chunked.count {
                guard var end = BodyEnd(.chunked) else { return Check.expectTrue(false) }
                var used = 0
                let all = chunked + Data("next".utf8)
                var index = 0
                while index < all.count, !end.isEnded {
                    let piece = Data(all[index..<min(index + size, all.count)])
                    used += (try? end.take(piece)) ?? -1000
                    index += piece.count
                }
                Check.expectTrue(end.isEnded, "in pieces of \(size)")
                Check.expectEqual(used, chunked.count, "in pieces of \(size)")
            }
            guard var length = BodyEnd(.length(3)), let none = BodyEnd(.none) else { return Check.expectTrue(false) }
            Check.expectEqual(try? length.take(Data("ab".utf8)), 2)
            Check.expectFalse(length.isEnded)
            Check.expectEqual(try? length.take(Data("cde".utf8)), 1)
            Check.expectTrue(length.isEnded)
            Check.expectTrue(none.isEnded)
            Check.expectTrue(BodyEnd(.untilClose) == nil)
            for bad in ["zz\r\n", "\r\n", "-1\r\n", "+5\r\nhello\r\n", "5\nhello", "1\r\nab\r\n", "FFFFFFFFFFFFFFFF\r\n"] {
                var end = BodyEnd(.chunked)!
                Check.expectNil(try? end.take(Data(bad.utf8)), bad.debugDescription)
            }
        }

        Check.test("whether a connection is kept, as each side says (#741)") {
            func keeps(_ head: String) -> Bool? { ((try? HTTPHead.parse(Data((head + "\r\n\r\n").utf8))) ?? nil)?.head.keepsConnection }
            Check.expectEqual(keeps("GET / HTTP/1.1\r\nHost: a"), true)
            Check.expectEqual(keeps("GET / HTTP/1.1\r\nConnection: Keep-Alive, Close"), false)
            Check.expectEqual(keeps("GET / HTTP/1.0\r\nConnection: keep-alive"), false)
            Check.expectEqual(keeps("HTTP/1.1 200 OK\r\nConnection: keep-alive"), true)
            Check.expectEqual(keeps("HTTP/1.1 200"), true)
            Check.expectEqual(keeps("HTTP/1.1 200 OK\r\nconnection: close"), false)
            Check.expectEqual(keeps("HTTP/1.0 200 OK"), false)
        }

        Check.test("only codings it can read are asked for (#741)") {
            Check.expectEqual(BodyCoding.readable("gzip, deflate, br, zstd"), "gzip, deflate, br")
            Check.expectEqual(BodyCoding.readable("br;q=1.0, zstd;q=0.9, dcb, *;q=0.1"), "br;q=1.0")
            Check.expectEqual(BodyCoding.readable("zstd"), "identity")
        }

        Check.test("ad slots: which sites and paths have them, and only names are changed (#741)") {
            let all = ["adPlacements", "adSlots", "playerAds"]
            for page in ["/watch?v=x", "/@name/live", "/clip/x", "/shorts/x", "/"] {
                Check.expectEqual(AdSlots.names(host: "www.youtube.com", target: page, page: true), all, page)
            }
            Check.expectEqual(AdSlots.names(host: "www.youtube-nocookie.com", target: "/embed/x", page: true), all)
            Check.expectEqual(AdSlots.names(host: "M.YouTube.com", target: "/youtubei/v1/player?prettyPrint=false", page: false), all)
            Check.expectEqual(AdSlots.names(host: "www.youtube.com", target: "/youtubei/v1/next", page: false), [])
            Check.expectEqual(AdSlots.names(host: "notyoutube.com", target: "/watch", page: true), [])
            Check.expectEqual(AdSlots.names(host: "youtube.com.example", target: "/watch", page: true), [])
            func renamed(_ text: String) -> String? {
                AdSlots.renamed(["adSlots"], in: Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
            }
            Check.expectEqual(renamed("{\"adSlots\":[]}"), "{\"_dSlots\":[]}")
            Check.expectEqual(renamed("\"{\\\"adSlots\\\" :[]}\""), "\"{\\\"_dSlots\\\" :[]}\"", "in a string")
            Check.expectEqual(renamed("'\\x7b\\x22adSlots\\x22:'"), "'\\x7b\\x22_dSlots\\x22:'", "in a script's string")
            Check.expectNil(renamed("{\"title\":\"adSlots\"}"), "a value")
            Check.expectNil(renamed("x.adSlots=1;\"myadSlots\":1,\"adSlotsX\":2,\"adSlots\""))
            Check.expectNil(renamed(""))
            let sliced = Data("xx{\"adSlots\":1}".utf8).dropFirst(2)
            Check.expectEqual(AdSlots.renamed(["adSlots"], in: sliced), Data("{\"_dSlots\":1}".utf8))
        }

        Check.test("a page whose only change is its ad slots keeps the rest, its policy too (#741)") {
            let html = "<p>{\"adSlots\":[]}</p>"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Security-Policy: script-src 'self'\r\n"
            let (bytes, untouched) = PageRewriter.rewrite(
                response: Data((head + "Content-Length: \(html.utf8.count)\r\n\r\n" + html).utf8), requestMethod: "GET",
                additions: PageAdditions(selectors: [], scriptlets: []), slots: ["adSlots"])
            Check.expectNil(untouched)
            Check.expectEqual(String(decoding: bytes, as: UTF8.self),
                              head + "Content-Length: \(html.utf8.count)\r\n\r\n<p>{\"_dSlots\":[]}</p>")
        }
    }
}

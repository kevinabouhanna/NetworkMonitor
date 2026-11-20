import FirewallPolicy
import Foundation

/// Requests refused by their address (#699), for Enhanced ad blocking (#256).
func runAddressRulesTests() {
    func request(_ url: String, page: String? = "www.news.example", kind: RequestKind = .script,
                 thirdParty: Bool? = nil) -> AddressRequest {
        let host = URLComponents(string: url)?.host ?? ""
        let party = thirdParty ?? page.map { SiteName.site(of: $0) != SiteName.site(of: host) }
        return AddressRequest(url: url, host: host, pageHost: page, kind: kind, isThirdParty: party)
    }

    Check.suite("Rules by address — reading a list (#699)") {

        Check.test("anchors, wildcards and options are read") {
            Check.expectEqual(AddressRule.parse("||ads.example.com/banner/*.js$script,third-party"),
                              AddressRule(pattern: "ads.example.com/banner/*.js", hostAnchored: true, kinds: .script,
                                          thirdParty: true))
            Check.expectEqual(AddressRule.parse("|https://cdn.example/ad.js|"),
                              AddressRule(pattern: "https://cdn.example/ad.js", startAnchored: true, endAnchored: true))
            Check.expectEqual(AddressRule.parse("/Banner/*$image,~third-party,domain=a.com|~b.a.com"),
                              AddressRule(pattern: "/banner/", kinds: .image, thirdParty: false, domains: ["a.com"],
                                          notDomains: ["b.a.com"]))
            Check.expectEqual(AddressRule.parse("@@||cdn.example/ads.js$script,domain=shop.example"),
                              AddressRule(isException: true, pattern: "cdn.example/ads.js", hostAnchored: true,
                                          kinds: .script, domains: ["shop.example"]))
            Check.expectEqual(AddressRule.parse("/ads.$~image,~script")?.kinds,
                              RequestKind.allButDocument.subtracting([.image, .script]))
            Check.expectEqual(AddressRule.parse("/AdFrame.$match-case")?.pattern, "/AdFrame.")
            Check.expectEqual(AddressRule.parse("@@||site.example^$document")?.wholePage, true)
            Check.expectEqual(AddressRule.parse("||ads.example^$redirect=noopjs,script")?.kinds, .script)
        }

        Check.test("what it doesn't do is left out, never read as something else") {
            for line in ["! a comment", "[Adblock Plus 2.0]", "example.com##.ad", "example.com#@#.ad",
                         "example.com##+js(set, a, b)", "/^https?:\\/\\/ads\\./$script", "||popup.example^$popup",
                         "||ads.example^$document", "@@||site.example^$generichide", "@@||site.example^$elemhide",
                         "||example.com^$csp=script-src 'none'", "||example.com/x$removeparam=utm",
                         "||example.com^$rewrite=abp-resource:blank-js", "*$script", ""] {
                Check.expectNil(AddressRule.parse(line), line)
            }
        }

        Check.test("a sample list: names, addresses and exceptions, and !#if blocks left out") {
            let list = """
            [Adblock Plus 2.0]
            ! Title: sample
            ||adserver.example^
            ||tracker.example^$third-party
            /banner/ads/*
            -ad-300x250.
            @@||news.example/banner/ads/house.png$image
            example.com##.ad
            !#if env_safari
            /only-safari-ad.
            !#endif
            """
            let rules = PageRules(listText: list)
            Check.expectEqual(rules.addresses.count, 5)
            Check.expectEqual(rules.forPage(on: "example.com").selectors.last, ".ad", "page rules still read")
            Check.expectTrue(rules.addresses.refuses(request("https://cdn.example/banner/ads/x.js")))
            Check.expectFalse(rules.addresses.refuses(request("https://cdn.example/only-safari-ad.js")))
            guard let data = try? rules.encoded(), let back = PageRules.decode(data) else {
                return Check.expectTrue(false, "didn't travel")
            }
            Check.expectEqual(back.addresses, rules.addresses)
            Check.expectTrue(back.addresses.refuses(request("https://img.example/x-ad-300x250.png", kind: .image)))
        }
    }

    Check.suite("Rules by address — what's refused (#699)") {
        let rules = AddressRules(lines: [
            "||adserver.example^",
            "||tracker.example^$third-party",
            "||cdn.example/ads/*.js$script",
            "/banner/ads/*",
            "-ad-300x250.",
            "|https://exact.example/ad.js|",
            "/pixel.gif?$image,domain=shop.example|~checkout.shop.example",
            "/AdFrame.$match-case",
            "||widgets.example/promo^$important",
            "@@||news.example/banner/ads/house.png$image",
            "@@||widgets.example/promo^",
            "@@||partner.example^$document",
        ])

        Check.test("a request whose address matches is refused") {
            Check.expectTrue(rules.refuses(request("https://adserver.example/x.js")), "a whole host")
            Check.expectTrue(rules.refuses(request("https://eu.adserver.example/x.js")), "and every name under it")
            Check.expectFalse(rules.refuses(request("https://notadserver.example/x.js")), "but not a name ending alike")
            Check.expectTrue(rules.refuses(request("https://cdn.example/ads/v2/load.js")))
            Check.expectTrue(rules.refuses(request("https://img.example/x/banner/ads/1.png", kind: .image)))
            Check.expectTrue(rules.refuses(request("https://img.example/x-ad-300x250.png", kind: .image)))
            Check.expectTrue(rules.refuses(request("https://exact.example/ad.js")))
            Check.expectFalse(rules.refuses(request("https://exact.example/ad.js?v=2")), "| ends the address")
            Check.expectTrue(rules.refuses(request("https://x.example/AdFrame.html", kind: .subdocument)))
            Check.expectFalse(rules.refuses(request("https://x.example/adframe.html", kind: .subdocument)), "$match-case")
            Check.expectFalse(rules.refuses(request("https://news.example/story.js")))
        }

        Check.test("options: its kind, another site's, on which pages") {
            Check.expectFalse(rules.refuses(request("https://cdn.example/ads/v2/load.js", kind: .image)), "$script only")
            Check.expectTrue(rules.refuses(request("https://tracker.example/t.js", page: "www.news.example")))
            Check.expectFalse(rules.refuses(request("https://tracker.example/t.js", page: "www.tracker.example")),
                              "$third-party: not on its own site")
            Check.expectFalse(rules.refuses(request("https://tracker.example/t.js", page: nil, thirdParty: nil)),
                              "$third-party: not when it can't be told")
            Check.expectTrue(rules.refuses(request("https://img.example/pixel.gif?id=1", page: "www.shop.example",
                                                   kind: .image)))
            Check.expectFalse(rules.refuses(request("https://img.example/pixel.gif?id=1", page: "checkout.shop.example",
                                                    kind: .image)), "~domain")
            Check.expectFalse(rules.refuses(request("https://img.example/pixel.gif?id=1", page: "www.other.example",
                                                    kind: .image)), "domain= elsewhere")
        }

        Check.test("an exception lets it through, and an important rule only for an important exception") {
            Check.expectFalse(rules.refuses(request("https://news.example/banner/ads/house.png", kind: .image)))
            Check.expectTrue(rules.refuses(request("https://news.example/banner/ads/house.png", kind: .xmlhttprequest)),
                             "the exception is for images")
            Check.expectTrue(rules.refuses(request("https://widgets.example/promo/1.js")), "$important")
            Check.expectFalse(rules.refuses(request("https://adserver.example/x.js", page: "www.partner.example")),
                              "@@…$document: nothing on that page")
        }

        Check.test("a page itself is never refused") {
            Check.expectFalse(rules.refuses(request("https://adserver.example/", kind: .document)))
        }
    }

    Check.suite("Rules by address — a browser's request (#699)") {
        Check.test("its kind, its page and whether it's another site's, from its head") {
            let headers = ["Sec-Fetch-Dest": "script", "Sec-Fetch-Site": "cross-site",
                           "Referer": "https://www.news.example/story/1"]
            let read = AddressRequest(host: "CDN.Example", target: "/ads/x.js?a=1", header: { headers[$0] })
            Check.expectEqual(read, AddressRequest(url: "https://cdn.example/ads/x.js?a=1", host: "cdn.example",
                                                   pageHost: "www.news.example", kind: .script, isThirdParty: true))
            let noFetch = ["Accept": "image/avif,image/webp", "Origin": "https://shop.example"]
            let image = AddressRequest(host: "img.shop.example", port: 8443, target: "/p.gif", header: { noFetch[$0] })
            Check.expectEqual(image.kind, .image)
            Check.expectEqual(image.url, "https://img.shop.example:8443/p.gif")
            Check.expectEqual(image.isThirdParty, false, "compared by site when the browser doesn't say")
            Check.expectEqual(RequestKind.of(fetchDest: "empty", accept: nil), .xmlhttprequest)
            Check.expectEqual(RequestKind.of(fetchDest: "iframe", accept: nil), .subdocument)
            Check.expectEqual(RequestKind.of(fetchDest: nil, accept: "text/html,application/xhtml+xml"), .document)
            Check.expectEqual(RequestKind.of(fetchDest: nil, accept: nil, upgrade: "websocket"), .websocket)
        }
    }

    Check.suite("Rules by address — the copy in the app (#699)") {
        let url = URL(fileURLWithPath: "Resources/Blocklists").appendingPathComponent(PageRules.fileName)
        let shipped = (try? Data(contentsOf: url)).flatMap(PageRules.decode)

        Check.test("EasyList's and EasyPrivacy's rules by address are in it") {
            guard let shipped else { return Check.expectTrue(false, "no \(url.path)") }
            Check.expectTrue(shipped.addresses.count >= PageRules.minimumAddresses, "\(shipped.addresses.count) rules")
        }

        Check.test("one address is matched in under 50 µs") {
            guard let shipped else { return Check.expectTrue(false, "no \(url.path)") }
            let requests = [
                request("https://www.theguardian.com/uk/news/2026/nov/20/a-long-story-about-something?page=2",
                        page: "www.theguardian.com", kind: .document),
                request("https://securepubads.g.doubleclick.net/tag/js/gpt.js", page: "www.bbc.com"),
                request("https://static.files.bbci.co.uk/core/website/assets/static/webcore/js/main.abc123.js",
                        page: "www.bbc.com"),
                request("https://i.guim.co.uk/img/media/abcdef/0_0_5000_3000/master/5000.jpg?width=620&quality=85",
                        page: "www.theguardian.com", kind: .image),
                request("https://www.google-analytics.com/g/collect?v=2&tid=G-XYZ&cid=1.2&en=page_view",
                        page: "www.example.com", kind: .ping),
                request("https://cdn.example.org/assets/banner-ad-300x250.png", page: "news.example.org", kind: .image),
                request("https://api.example.net/v1/feed?cursor=abc&limit=20", page: "app.example.net",
                        kind: .xmlhttprequest),
            ]
            _ = shipped.addresses.refuses(requests[1])
            // The best of five rounds, as for the page rules: what a match
            // costs, not what other work on the Mac took from it.
            var each = Double.infinity
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                let rounds = 700
                for round in 0..<rounds { _ = shipped.addresses.refuses(requests[round % requests.count]) }
                let took = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                each = min(each, took / Double(rounds))
            }
            let limit = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 0.000_050 : 0.000_500
            Check.expectTrue(each < limit, "\(Int(each * 1_000_000)) µs each")
            Check.expectTrue(shipped.addresses.refuses(requests[4]), "Google Analytics' collect is refused")
            Check.expectFalse(shipped.addresses.refuses(requests[3]), "a news picture isn't")
        }
    }
}

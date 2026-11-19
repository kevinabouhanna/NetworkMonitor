import FirewallPolicy
import Foundation

/// The rules for inside pages (#681), for Enhanced ad blocking (#256).
func runPageRulesTests() {
    Check.suite("Page rules — reading a list (#681)") {

        Check.test("hiding, exceptions and scriptlets, for every page or by site") {
            Check.expectEqual(PageRule.parse("##.ad-banner"), PageRule(action: .hide(".ad-banner"), sites: [], notOn: []))
            Check.expectEqual(PageRule.parse("example.com,~shop.example.com##div[id^=\"ad-\"]"),
                              PageRule(action: .hide("div[id^=\"ad-\"]"), sites: ["example.com"], notOn: ["shop.example.com"]))
            Check.expectEqual(PageRule.parse("news.example#@#.sponsor"),
                              PageRule(action: .unhide(".sponsor"), sites: ["news.example"], notOn: []))
            Check.expectEqual(PageRule.parse("youtube.com##+js(json-prune, playerResponse.adPlacements, , )"),
                              PageRule(action: .scriptlet(Scriptlet(name: "json-prune", arguments: ["playerResponse.adPlacements"])),
                                       sites: ["youtube.com"], notOn: []))
            Check.expectEqual(PageRule.parse("x.com##+js(set, navigator.globalPrivacyControl, false)"),
                              PageRule(action: .scriptlet(Scriptlet(name: "set-constant",
                                                                    arguments: ["navigator.globalPrivacyControl", "false"])),
                                       sites: ["x.com"], notOn: []))
            Check.expectEqual(PageRule.parse("example.org#%#//scriptlet('abort-on-property-read', 'adsbygoogle')"),
                              PageRule(action: .scriptlet(Scriptlet(name: "abort-on-property-read", arguments: ["adsbygoogle"])),
                                       sites: ["example.org"], notOn: []))
        }

        Check.test("what Enhanced ad blocking can't do yet is left out, never half read") {
            for line in ["! a comment", "[Adblock Plus 2.0]", "||ads.example.com^", "example.com#?#div:-abp-has(.ad)",
                         "example.com#$#abort-on-property-read ads", "example.com##div:has(> .ad)",
                         "example.com##+js(some-unknown-scriptlet, x)", "/^https?:\\/\\/ad/##.ad",
                         "example.com##.ad { color: red }", "example.com$$script[tag-content=\"ad\"]"] {
                Check.expectNil(PageRule.parse(line), line)
            }
        }
    }

    Check.suite("Page rules — what a page gets (#681)") {
        let rules = PageRules(listText: """
            ##.ad-banner
            ##.promo
            ~quiet.example##.loud-ad
            example.com##.site-ad
            example.com,~shop.example.com##.not-in-shop
            shop.example.com#@#.ad-banner
            softonic.*##.sponsored
            youtube.com##+js(json-prune, playerResponse.adPlacements)
            #@#.promo
            """)

        Check.test("every page gets the generic rules, and an exception everywhere removes one") {
            Check.expectEqual(rules.generic, [".ad-banner"])
            let page = rules.forPage(on: "elsewhere.org")
            Check.expectEqual(page.selectors, [".ad-banner", ".loud-ad"])
            Check.expectEqual(page.scriptlets, [])
        }

        Check.test("a site gets its own, and so do the names under it") {
            Check.expectEqual(rules.forPage(on: "www.example.com").selectors,
                              [".ad-banner", ".site-ad", ".not-in-shop", ".loud-ad"])
        }

        Check.test("a site's exceptions, and ~site, leave it alone there") {
            Check.expectEqual(rules.forPage(on: "shop.example.com").selectors, [".site-ad", ".loud-ad"])
            Check.expectEqual(rules.forPage(on: "quiet.example").selectors, [".ad-banner"])
        }

        Check.test("name.* covers the name under any public suffix") {
            Check.expectTrue(rules.forPage(on: "en.softonic.com").selectors.contains(".sponsored"))
            Check.expectTrue(rules.forPage(on: "softonic.co.uk").selectors.contains(".sponsored"))
            Check.expectFalse(rules.forPage(on: "notsoftonic.com").selectors.contains(".sponsored"))
        }

        Check.test("a site's scriptlets, with their arguments") {
            Check.expectEqual(rules.forPage(on: "www.youtube.com").scriptlets,
                              [Scriptlet(name: "json-prune", arguments: ["playerResponse.adPlacements"])])
        }

        Check.test("they travel as pages.bin and read back the same") {
            guard let data = try? rules.encoded(), let back = PageRules.decode(data) else {
                return Check.expectTrue(false, "didn't encode or decode")
            }
            Check.expectEqual(back, rules)
            Check.expectEqual(back.forPage(on: "www.example.com"), rules.forPage(on: "www.example.com"))
        }
    }

    Check.suite("Page rules — the copy in the app (#681)") {
        let url = URL(fileURLWithPath: "Resources/Blocklists").appendingPathComponent(PageRules.fileName)
        let shipped = (try? Data(contentsOf: url)).flatMap(PageRules.decode)

        Check.test("is there, from EasyList and EasyPrivacy, credited") {
            guard let shipped else { return Check.expectTrue(false, "no \(url.path)") }
            Check.expectTrue(shipped.generic.count >= PageRules.minimumGeneric, "\(shipped.generic.count) generic")
            Check.expectTrue(shipped.siteCount > 1_000, "\(shipped.siteCount) sites")
            let sources = (try? String(contentsOf: URL(fileURLWithPath: "Resources/Blocklists/SOURCES.md"),
                                       encoding: .utf8)) ?? ""
            Check.expectTrue(sources.contains("EasyList") && sources.contains("CC BY-SA 3.0"), "SOURCES.md credits them")
        }

        Check.test("one site's rules are read in under a millisecond") {
            guard let shipped else { return Check.expectTrue(false, "no \(url.path)") }
            let hosts = ["www.example.com", "news.bbc.co.uk", "www.youtube.com", "en.softonic.com", "a.b.c.d.example.org"]
            _ = shipped.forPage(on: hosts[0])
            let start = Date()
            let rounds = 200
            for round in 0..<rounds { _ = shipped.forPage(on: hosts[round % hosts.count]) }
            let each = Date().timeIntervalSince(start) / Double(rounds)
            Check.expectTrue(each < 0.001, "\(Int(each * 1_000_000)) µs each")
        }
    }
}

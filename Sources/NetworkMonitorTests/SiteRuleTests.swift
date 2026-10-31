import FirewallPolicy
import Foundation
import NetworkMonitorCore

// #197: a rule for a site by name covers the name and every name under it,
// sits between a server and an app, and is what a named server row offers.

func runSiteRuleTests() {
    func rule(_ subject: RuleSubject, _ key: String, _ action: RuleAction) -> FirewallRule {
        FirewallRule(subject: subject, key: key, title: key, action: action)
    }

    /// Chrome reaching an ad server on Google's network, named by its handshake.
    let chromeToAds = FlowFacts(appKeys: ["/Applications/Google Chrome.app"], companyKey: "Google", country: "US",
                                address: "142.251.39.174", port: 443, isApple: false,
                                hostname: "static.doubleclick.net")

    Check.suite("Site names (#197)") {

        Check.test("a name and the domains above it, narrowest first, never a bare suffix") {
            Check.expectEqual(SiteName.domains(of: "a.static.doubleclick.net"),
                              ["a.static.doubleclick.net", "static.doubleclick.net", "doubleclick.net"])
            Check.expectEqual(SiteName.domains(of: "news.bbc.co.uk"), ["news.bbc.co.uk", "bbc.co.uk"])
            Check.expectEqual(SiteName.domains(of: "Example.COM."), ["example.com"])
            Check.expectEqual(SiteName.domains(of: "142.251.39.174"), [])
            Check.expectEqual(SiteName.domains(of: "2a00:1450:4006::200e"), [])
            Check.expectEqual(SiteName.domains(of: "localhost"), [])
        }

        Check.test("the site a name belongs to") {
            Check.expectEqual(SiteName.site(of: "stats.wp.com"), "wp.com")
            Check.expectEqual(SiteName.site(of: "static.files.bbci.co.uk"), "bbci.co.uk")
            Check.expectEqual(SiteName.site(of: "kevinabouhanna.github.io"), "kevinabouhanna.github.io")
            Check.expectEqual(SiteName.site(of: "d1234.cloudfront.net"), "d1234.cloudfront.net")
            Check.expectEqual(SiteName.site(of: "wp.com"), "wp.com")
        }
    }

    Check.suite("Firewall — rules by site name (#197)") {

        Check.test("a site rule covers the name and every name under it") {
            for key in ["doubleclick.net", "static.doubleclick.net"] {
                let block = rule(.site, key, .block)
                Check.expectEqual(FirewallPolicy(rules: [block]).decide(chromeToAds), .block(.rule(block)), key)
            }
        }

        Check.test("but not a name that only ends the same way, nor a connection with no name") {
            let block = rule(.site, "doubleclick.net", .block)
            var lookalike = chromeToAds
            lookalike.hostname = "notdoubleclick.net"
            Check.expectEqual(FirewallPolicy(rules: [block]).decide(lookalike), .allow(.mode))
            var nameless = chromeToAds
            nameless.hostname = nil
            Check.expectEqual(FirewallPolicy(rules: [block]).decide(nameless), .allow(.mode))
            Check.expectEqual(FirewallPolicy(rules: [rule(.site, "net", .block)]).decide(chromeToAds), .allow(.mode),
                              "a bare suffix matches nothing")
        }

        Check.test("narrower than a company or an app, wider than a server, the longer name first") {
            let blockGoogle = rule(.company, "Google", .block)
            let allowSite = rule(.site, "doubleclick.net", .allow)
            Check.expectEqual(FirewallPolicy(rules: [blockGoogle, allowSite]).decide(chromeToAds),
                              .allow(.rule(allowSite)), "the site over its company")
            let blockChrome = rule(.app, "/Applications/Google Chrome.app", .block)
            Check.expectEqual(FirewallPolicy(rules: [blockChrome, allowSite]).decide(chromeToAds),
                              .allow(.rule(allowSite)), "the site over the app")
            let allowServer = rule(.server, "142.251.39.174", .allow)
            let blockSite = rule(.site, "doubleclick.net", .block)
            Check.expectEqual(FirewallPolicy(rules: [blockSite, allowServer]).decide(chromeToAds),
                              .allow(.rule(allowServer)), "the server over the site")
            let allowName = rule(.site, "static.doubleclick.net", .allow)
            Check.expectEqual(FirewallPolicy(rules: [blockSite, allowName]).decide(chromeToAds),
                              .allow(.rule(allowName)), "the name over its site")
        }

        Check.test("on hotspots, only on hotspots") {
            let hotspots = rule(.site, "doubleclick.net", .blockOnHotspots)
            Check.expectEqual(FirewallPolicy(rules: [hotspots]).decide(chromeToAds), .allow(.mode))
            Check.expectEqual(FirewallPolicy(rules: [hotspots], onHotspot: true).decide(chromeToAds),
                              .block(.rule(hotspots)))
        }

        Check.test("a policy with site rules survives the trip to the filter") {
            let policy = FirewallPolicy(rules: [rule(.site, "doubleclick.net", .block)])
            Check.expectEqual(FirewallPolicy.decode(policy.encoded()), policy)
        }
    }

    Check.suite("Connections — rules on a named server (#197)") {

        func server(_ title: String, _ address: String) -> ConnectionsItem {
            ConnectionsItem(dimension: .server, key: address, title: title, subtitle: address, isHost: false,
                            symbol: nil, bundlePath: nil)
        }

        Check.test("a server with a name offers the name and its whole site") {
            Check.expectEqual(FirewallRules.serverName(of: server("stats.wp.com", "192.0.77.32")), "stats.wp.com")
            Check.expectNil(FirewallRules.serverName(of: server("192.0.77.32", "192.0.77.32")))
            Check.expectEqual(FirewallRules.siteScopes(for: "stats.wp.com"), ["stats.wp.com", "wp.com"])
            Check.expectEqual(FirewallRules.siteScopes(for: "wp.com"), ["wp.com"])
        }

        Check.test("its row shows the narrowest site rule covering it, then its address's") {
            let defaults = UserDefaults(suiteName: "site-rules-\(UUID().uuidString)")!
            let firewall = FirewallRules(defaults: defaults)
            let row = server("stats.wp.com", "192.0.77.32")
            Check.expectNil(firewall.rule(for: row))
            firewall.set(.block, for: row)
            Check.expectEqual(firewall.rule(for: row)?.subject, .server)
            firewall.setSite(.blockOnHotspots, domain: "wp.com", forName: "stats.wp.com")
            Check.expectEqual(firewall.rule(for: row)?.key, "wp.com")
            Check.expectEqual(firewall.rule(for: row)?.title, "*.wp.com")
            firewall.setSite(.allow, domain: "stats.wp.com", forName: "stats.wp.com")
            Check.expectEqual(firewall.rule(for: row)?.key, "stats.wp.com")
            Check.expectEqual(firewall.rule(for: row)?.title, "stats.wp.com")
            Check.expectEqual(firewall.rule(for: server("pixel.wp.com", "192.0.77.40"))?.key, "wp.com")
        }
    }
}

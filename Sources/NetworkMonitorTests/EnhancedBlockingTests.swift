import FirewallPolicy
import Foundation

/// Which connections Enhanced ad blocking opens (#684).
func runEnhancedBlockingTests() {
    let on = EnhancedBlocking(isOn: true)

    Check.suite("Enhanced ad blocking — which connections it opens (#684)") {

        Check.test("switched off (the default), nothing is opened") {
            let off = EnhancedBlocking()
            Check.expectFalse(off.isOn)
            Check.expectEqual(off.decide(app: "com.apple.Safari", host: "news.example", port: 443, isUDP: false),
                              .leave(.off))
            Check.expectEqual(off.decide(app: "com.google.Chrome", host: "news.example", port: 443, isUDP: true),
                              .leave(.off))
        }

        Check.test("a browser's secure page is opened; its QUIC refused so it uses TCP") {
            Check.expectEqual(on.decide(app: "com.apple.Safari", host: "news.example", port: 443, isUDP: false), .open)
            Check.expectEqual(on.decide(app: "com.google.Chrome.helper", host: "news.example", port: 443, isUDP: false),
                              .open)
            Check.expectEqual(on.decide(app: "com.google.Chrome.helper.renderer", host: "news.example", port: 443,
                                        isUDP: false), .open, "a helper of a helper")
            Check.expectEqual(on.decide(app: "com.google.Chrome", host: "news.example", port: 443, isUDP: true),
                              .refuseQUIC)
        }

        Check.test("other apps, other ports, no name: left alone") {
            Check.expectEqual(on.decide(app: "com.tinyspeck.slackmacgap", host: "slack.com", port: 443, isUDP: false),
                              .leave(.notAnAppItReaches))
            Check.expectEqual(on.decide(app: nil, host: "news.example", port: 443, isUDP: false), .leave(.notAnAppItReaches))
            Check.expectEqual(on.decide(app: "com.apple.Safari", host: "news.example", port: 80, isUDP: false),
                              .leave(.notWeb))
            Check.expectEqual(on.decide(app: "com.apple.Safari", host: nil, port: 443, isUDP: false), .leave(.noName))
            var chosen = on
            chosen.apps.insert("com.tinyspeck.slackmacgap")
            Check.expectEqual(chosen.decide(app: "com.tinyspeck.slackmacgap", host: "slack.com", port: 443, isUDP: false),
                              .open, "an app the person chose")
        }

        Check.test("banking, health, government and payment sites are never opened, QUIC included") {
            for host in ["www.chase.com", "secure.paypal.com", "www.gov.uk", "impots.gouv.fr", "www.irs.gov",
                         "mychart.example.health", "online.bank", "www.nhs.uk", "e-gov.go.jp", "my.kp.org",
                         "appleid.apple.com", "mabanque.bnpparibas"] {
                Check.expectEqual(on.decide(app: "com.apple.Safari", host: host, port: 443, isUDP: false),
                                  .leave(.neverOpened), host)
                Check.expectEqual(on.decide(app: "com.google.Chrome", host: host, port: 443, isUDP: true),
                                  .leave(.neverOpened), "\(host), QUIC")
            }
            Check.expectFalse(EnhancedBlocking.isNeverOpened("espn.go.com"), "go.com isn't a government")
            Check.expectFalse(EnhancedBlocking.isNeverOpened("www.youtube.com"))
        }

        Check.test("a site the person excludes, and an app that pins its certificate, are left alone") {
            var settings = on
            settings.excludedSites = ["example.org"]
            settings.pinnedApps = ["com.vendor.pinned"]
            settings.apps.insert("com.vendor.pinned")
            Check.expectEqual(settings.decide(app: "com.apple.Safari", host: "shop.example.org", port: 443, isUDP: false),
                              .leave(.excluded))
            Check.expectEqual(settings.decide(app: "com.vendor.pinned", host: "api.vendor.com", port: 443, isUDP: false),
                              .leave(.pinned))
        }

        Check.test("the settings travel to the filter and back the same") {
            var settings = on
            settings.excludedSites = ["example.org"]
            let data = try? JSONEncoder().encode(settings)
            Check.expectEqual(data.flatMap { try? JSONDecoder().decode(EnhancedBlocking.self, from: $0) }, settings)
        }
    }
}

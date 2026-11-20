import CryptoKit
import FirewallPolicy
import Foundation
import NetworkMonitorCore
import Security
import SiteCertificates
import X509

/// Enhanced ad blocking's switch in Settings (#685): the apps it reaches,
/// what the filter is sent, and turning it on (approved, or not) and off.
func runEnhancedSwitchTests() {
    Check.suite("Enhanced ad blocking — the apps it reaches (#685)") {

        Check.test("each browser listed once, its helpers going with it; Canary an app of its own") {
            let listed = EnhancedBlocking.browserApps
            Check.expectTrue(listed.contains("com.google.Chrome") && listed.contains("com.google.Chrome.canary"), "\(listed)")
            Check.expectFalse(listed.contains { $0.lowercased().contains(".helper") }, "no helper: \(listed)")
            Check.expectTrue(listed.contains("company.thebrowser.Browser"))
        }

        Check.test("a browser taken away goes with its helpers, and comes back with them") {
            var settings = EnhancedBlocking(isOn: true)
            settings.setReaches("com.google.Chrome", false)
            Check.expectFalse(settings.reaches("com.google.Chrome"))
            Check.expectEqual(settings.decide(app: "com.google.Chrome.helper", host: "news.example", port: 443, isUDP: false),
                              .leave(.notAnAppItReaches), "its helper too")
            Check.expectTrue(settings.reaches("com.google.Chrome.canary"), "Canary isn't Chrome")
            settings.setReaches("company.thebrowser.Browser", false)
            Check.expectEqual(settings.decide(app: "company.thebrowser.browser.helper", host: "news.example", port: 443,
                                              isUDP: false), .leave(.notAnAppItReaches), "Arc's lowercase helper")
            settings.setReaches("com.google.Chrome", true)
            Check.expectEqual(settings.decide(app: "com.google.Chrome.helper", host: "news.example", port: 443, isUDP: false),
                              .open)
            Check.expectTrue(settings.addedApps.isEmpty, "a browser isn't added: \(settings.addedApps)")
        }

        Check.test("Canary taken away while Chrome stays: Canary's connections aren't opened, Chrome's are") {
            var settings = EnhancedBlocking(isOn: true)
            settings.setReaches("com.google.Chrome.canary", false)
            Check.expectEqual(settings.decide(app: "com.google.Chrome.canary", host: "news.example", port: 443, isUDP: false),
                              .leave(.notAnAppItReaches))
            Check.expectEqual(settings.decide(app: "com.google.Chrome.helper.renderer", host: "news.example", port: 443,
                                              isUDP: false), .open)
            let pinnedChrome = EnhancedBlocking(isOn: true, pinnedApps: ["com.google.Chrome"])
            Check.expectEqual(pinnedChrome.decide(app: "com.google.Chrome.canary", host: "news.example", port: 443,
                                                  isUDP: false), .open, "Chrome left alone isn't Canary")
        }

        Check.test("an app added is reached, and taken away again; an app left alone is tried again") {
            var settings = EnhancedBlocking(isOn: true, pinnedApps: ["com.dropbox.client", "com.spotify.client.helper"])
            settings.setReaches("com.spotify.client", true)
            Check.expectEqual(settings.addedApps, ["com.spotify.client"])
            Check.expectTrue(settings.reaches("com.spotify.client"))
            settings.forgetPinned("com.spotify.client")
            Check.expectEqual(settings.pinnedApps, ["com.dropbox.client"], "the helper with it")
            settings.setReaches("com.spotify.client", false)
            Check.expectFalse(settings.reaches("com.spotify.client"))
            Check.expectTrue(settings.addedApps.isEmpty && settings.removedApps.isEmpty, "nothing kept for an added app")
        }
    }

    Check.suite("Enhanced ad blocking — what the filter is sent (#685)") {

        Check.test("kept across a relaunch, off at first, and read from an older copy without the root") {
            let defaults = Check.defaults("enhanced-switch")
            Check.expectEqual(FirewallRules(defaults: defaults, teamOf: { _ in nil }).enhancedBlocking, EnhancedBlocking())
            let rules = FirewallRules(defaults: defaults, teamOf: { _ in nil })
            rules.enhancedBlocking.isOn = true
            rules.enhancedBlocking.trustedRoot = "ab12"
            Check.expectEqual(FirewallRules(defaults: defaults, teamOf: { _ in nil }).enhancedBlocking.trustedRoot, "ab12")
            let older = Data(#"{"isOn":true,"addedApps":[],"removedApps":[],"excludedSites":[],"pinnedApps":["x"]}"#.utf8)
            let read = try? JSONDecoder().decode(EnhancedBlocking.self, from: older)
            Check.expectEqual(read?.pinnedApps, ["x"])
            Check.expectNil(read?.trustedRoot ?? nil)
        }

        Check.test("sites always allowed for every app are never opened, as banks' aren't; one app's aren't") {
            let rules = [AdRule(kind: .neverBlock, site: "shop.example"),
                         AdRule(kind: .neverBlock, site: "only-mail.example", appKey: "/Applications/Mail.app"),
                         AdRule(kind: .alwaysBlock, site: "tracker.example")]
            let policy = FirewallRules.enhancedPolicy(EnhancedBlocking(isOn: true), adRules: rules)
            Check.expectEqual(policy.excludedSites, ["shop.example"])
            Check.expectEqual(policy.decide(app: "com.apple.Safari", host: "www.shop.example", port: 443, isUDP: false),
                              .leave(.excluded))
            Check.expectTrue(FirewallRules.enhancedPolicy(EnhancedBlocking(), adRules: [], onForTesting: true).isOn,
                             "on for a test run")
        }

        Check.test("the root's name is the one the filter makes") {
            Check.expectEqual(EnhancedRoot.name, CertificateAuthority.commonName)
        }
    }

    Check.suite("Enhanced ad blocking — switching it on and off (#685)") {
        guard let root = testRoot() else { return Check.test("a root to test with") { Check.expectTrue(false, "none") } }

        /// A controller over its own settings, whose root and trust are
        /// these: `made` once the filter has made it, `trusted` once approved.
        final class Mac {
            var made = false, trusted = false, answer = errSecSuccess
            var asked = 0, removed = 0
        }
        func controller(_ mac: Mac, on: Bool = false, trusted: Bool = false) -> (EnhancedBlockingController, FirewallRules) {
            let rules = FirewallRules(defaults: Check.defaults("enhanced-switch-\(UUID().uuidString)"), teamOf: { _ in nil })
            rules.enhancedBlocking.isOn = on
            mac.trusted = trusted
            let made = EnhancedBlockingController(
                firewall: rules, root: { mac.made ? root : nil }, isTrusted: { _ in mac.trusted },
                trust: { _ in mac.asked += 1; if mac.answer == errSecSuccess { mac.trusted = true }; return mac.answer },
                removeTrust: { _ in mac.removed += 1; mac.trusted = false; return errSecSuccess })
            return (made, rules)
        }
        func wait(until done: () -> Bool) {
            let deadline = Date() + 5
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }

        Check.test("switched on, it asks first; Cancel leaves it off") {
            let mac = Mac()
            let (enhanced, rules) = controller(mac)
            enhanced.setOn(true)
            Check.expectTrue(enhanced.asksToTurnOn)
            Check.expectFalse(rules.enhancedBlocking.isOn, "nothing until Continue")
            enhanced.cancelTurnOn()
            Check.expectFalse(enhanced.asksToTurnOn)
            Check.expectEqual(enhanced.status, .off)
        }

        Check.test("Continue: on, the root approved once the filter has made it, and the filter told which") {
            let mac = Mac()
            let (enhanced, rules) = controller(mac)
            enhanced.setOn(true)
            enhanced.confirmTurnOn()
            Check.expectTrue(rules.enhancedBlocking.isOn)
            Check.expectEqual(enhanced.status, .preparing)
            mac.made = true
            wait { enhanced.status == .on }
            Check.expectEqual(enhanced.status, .on)
            Check.expectEqual(mac.asked, 1, "asked once")
            Check.expectEqual(rules.enhancedBlocking.trustedRoot, EnhancedRoot.fingerprint(root))
        }

        Check.test("the password dialog cancelled: waiting for approval, and Try Again asks again") {
            let mac = Mac()
            mac.made = true
            mac.answer = errAuthorizationCanceled
            let (enhanced, rules) = controller(mac)
            enhanced.confirmTurnOn()
            wait { enhanced.status == .needsApproval }
            Check.expectEqual(enhanced.status, .needsApproval)
            Check.expectTrue(rules.enhancedBlocking.isOn, "the switch stays on")
            Check.expectNil(rules.enhancedBlocking.trustedRoot)
            mac.answer = errSecSuccess
            enhanced.tryAgain()
            wait { enhanced.status == .on }
            Check.expectEqual(enhanced.status, .on)
            Check.expectEqual(mac.asked, 2)
        }

        Check.test("at launch, on with a trusted root is on; with a new root it waits, never asking unasked") {
            let mac = Mac()
            mac.made = true
            let (trusted, _) = controller(mac, on: true, trusted: true)
            wait { trusted.status == .on }
            Check.expectEqual(trusted.status, .on)
            let renewed = Mac()
            renewed.made = true
            let (waiting, _) = controller(renewed, on: true, trusted: false)
            wait { waiting.status == .needsApproval }
            Check.expectEqual(waiting.status, .needsApproval)
            Check.expectEqual(renewed.asked, 0, "no password dialog at launch")
        }

        Check.test("switched off while macOS is still asking: the trust given then is taken away") {
            let mac = Mac()
            mac.made = true
            let gate = DispatchSemaphore(value: 0)
            let rules = FirewallRules(defaults: Check.defaults("enhanced-switch-\(UUID().uuidString)"), teamOf: { _ in nil })
            let enhanced = EnhancedBlockingController(
                firewall: rules, root: { root }, isTrusted: { _ in mac.trusted },
                trust: { _ in gate.wait(); mac.trusted = true; return errSecSuccess },
                removeTrust: { _ in mac.removed += 1; mac.trusted = false; return errSecSuccess })
            enhanced.confirmTurnOn()
            wait { enhanced.status == .approving }
            enhanced.setOn(false)
            gate.signal()   // the person approves in the dialog still open
            wait { mac.removed == 1 }
            Check.expectEqual(mac.removed, 1)
            Check.expectFalse(mac.trusted, "nothing trusted with the switch off")
            Check.expectEqual(enhanced.status, .off)
        }

        Check.test("on, but the root in use isn't the one approved: back to waiting for approval") {
            let mac = Mac()
            mac.made = true
            let (enhanced, rules) = controller(mac, on: true, trusted: true)
            wait { enhanced.status == .on }
            rules.enhancedBlocking.trustedRoot = "another root"
            enhanced.refresh()
            wait { enhanced.status == .needsApproval }
            Check.expectEqual(enhanced.status, .needsApproval)
        }

        Check.test("a browser's helper left alone is shown as the browser") {
            let mac = Mac()
            let (enhanced, rules) = controller(mac)
            rules.enhancedBlocking.pinnedApps = ["com.google.Chrome.helper", "com.dropbox.client"]
            Check.expectEqual(enhanced.leftAlone, ["com.dropbox.client", "com.google.Chrome"])
            enhanced.forgetLeftAlone("com.google.Chrome")
            Check.expectEqual(rules.enhancedBlocking.pinnedApps, ["com.dropbox.client"])
        }

        Check.test("switched off: off at once, the trust taken away, and the filter sent no root") {
            let mac = Mac()
            mac.made = true
            let (enhanced, rules) = controller(mac, on: true, trusted: true)
            wait { enhanced.status == .on }
            enhanced.setOn(false)
            Check.expectEqual(enhanced.status, .off)
            Check.expectFalse(rules.enhancedBlocking.isOn)
            Check.expectNil(rules.enhancedBlocking.trustedRoot)
            wait { mac.removed == 1 }
            Check.expectEqual(mac.removed, 1, "the trust removed")
            Check.expectFalse(mac.trusted)
        }
    }
}

/// A root certificate of the kind the filter makes, for the tests.
private func testRoot() -> SecCertificate? {
    guard let authority = try? CertificateAuthority.make(key: Certificate.PrivateKey(P256.Signing.PrivateKey()),
                                                         machine: "Test Mac"),
          let der = try? authority.der() else { return nil }
    return SecCertificateCreateWithData(nil, der as CFData)
}

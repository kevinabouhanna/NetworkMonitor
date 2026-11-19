import CryptoKit
import FirewallPolicy
import Foundation
import NetworkMonitorCore
import Security
import SiteCertificates
import X509

/// Enhanced ad blocking's transparent proxy (#702): what's configured with
/// the switch off and on, what it takes before reading a byte, the settings
/// in the policy the filter is sent, and the root kept in a keychain.
func runEnhancedProxyTests() {
    let on = EnhancedBlocking(isOn: true)

    Check.suite("Enhanced ad blocking — the transparent proxy (#702)") {

        Check.test("switched off, no proxy is configured, and one left from before is removed") {
            Check.expectEqual(EnhancedBlockingProxy.action(isOn: false, configured: 0), .nothing)
            Check.expectEqual(EnhancedBlockingProxy.action(isOn: false, configured: 1), .remove)
            Check.expectEqual(EnhancedBlockingProxy.action(isOn: false, configured: 3), .remove)
            Check.expectEqual(EnhancedBlockingProxy.action(isOn: true, configured: 0), .configure)
            Check.expectEqual(EnhancedBlockingProxy.action(isOn: true, configured: 1), .configure)
        }

        Check.test("off unless a run is started with the testing argument") {
            Check.expectFalse(EnhancedBlockingProxy.isOnForTesting)
            Check.expectFalse(FirewallPolicy().enhancedBlocking.isOn)
        }

        Check.test("the proxy's provider is the filter's system extension") {
            Check.expectEqual(EnhancedBlockingProxy.providerProtocol().providerBundleIdentifier,
                              "com.kevinabouhanna.NetworkMonitor.Filter")
        }

        Check.test("a browser's connection is taken to read its name, by address too; others are left before a byte") {
            Check.expectEqual(on.start(app: "com.apple.Safari", host: "news.example", port: 443), .readName)
            Check.expectEqual(on.start(app: "com.google.Chrome.helper", host: nil, port: 443), .readName)
            Check.expectEqual(on.start(app: "com.apple.Safari", host: "chase.com", port: 443), .leave(.neverOpened))
            Check.expectEqual(on.start(app: "com.apple.Mail", host: "news.example", port: 443), .leave(.notAnAppItReaches))
            Check.expectEqual(on.start(app: "com.apple.Safari", host: "news.example", port: 8443), .leave(.notWeb))
            Check.expectEqual(EnhancedBlocking().start(app: "com.apple.Safari", host: "news.example", port: 443),
                              .leave(.off))
            var pinned = on
            pinned.pinnedApps = ["com.apple.Safari"]
            Check.expectEqual(pinned.start(app: "com.apple.Safari", host: nil, port: 443), .leave(.pinned))
        }

        Check.test("the settings travel in the policy; a policy from before them reads them as off") {
            var policy = FirewallPolicy(enhancedBlocking: on)
            policy.enhancedBlocking.excludedSites = ["example.org"]
            Check.expectEqual(FirewallPolicy.decode(policy.encoded())?.enhancedBlocking, policy.enhancedBlocking)
            let old = Data(#"{"mode":"anywhere","rules":[]}"#.utf8)
            Check.expectEqual(FirewallPolicy.decode(old)?.enhancedBlocking, EnhancedBlocking())
            let unreadable = Data(#"{"mode":"anywhere","rules":[],"enhancedBlocking":7}"#.utf8)
            Check.expectEqual(FirewallPolicy.decode(unreadable)?.enhancedBlocking, EnhancedBlocking(),
                              "unreadable settings are off, never the policy lost")
        }

        Check.test("the root is kept in the keychain: found again, the same, until it's removed") {
            let path = NSTemporaryDirectory() + "proxy-root-\(UUID().uuidString).keychain"
            var made: SecKeychain?
            guard SecKeychainCreate(path, 4, "test", false, nil, &made) == errSecSuccess, let keychain = made else {
                return Check.expectTrue(false, "no test keychain")
            }
            defer { SecKeychainDelete(keychain); try? FileManager.default.removeItem(atPath: path) }
            do {
                let first = try AuthorityStore.load(in: keychain, machine: "Test Mac")
                Check.expectTrue(first.made)
                let again = try AuthorityStore.load(in: keychain, machine: "Test Mac")
                Check.expectFalse(again.made, "found again")
                Check.expectEqual(try again.authority.der(), try first.authority.der())
                Check.expectEqual(AuthorityStore.certificates(in: keychain).count, 1)
                Check.expectFalse(AuthorityKey.find(in: keychain).contains(where: AuthorityKey.isExportable))
                Check.expectTrue(AuthorityStore.remove(from: keychain), "nothing left")
                Check.expectTrue(AuthorityKey.find(in: keychain).isEmpty)
                Check.expectTrue(try AuthorityStore.load(in: keychain, machine: "Test Mac").made, "a new one after")
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }

        Check.test("a root is kept until it ends; an ended one, or a certificate without its key, is made again") {
            let path = NSTemporaryDirectory() + "proxy-root-\(UUID().uuidString).keychain"
            var made: SecKeychain?
            guard SecKeychainCreate(path, 4, "test", false, nil, &made) == errSecSuccess, let keychain = made else {
                return Check.expectTrue(false, "no test keychain")
            }
            defer { SecKeychainDelete(keychain); try? FileManager.default.removeItem(atPath: path) }
            do {
                let old = try AuthorityStore.load(in: keychain, machine: "Test Mac",
                                                  now: Date() - CertificateAuthority.lifetime + 7 * 24 * 3600)
                Check.expectFalse(try AuthorityStore.load(in: keychain, machine: "Test Mac").made,
                                  "a week from its end, still the trusted one")
                let renewed = try AuthorityStore.load(in: keychain, machine: "Test Mac", now: Date() + 8 * 24 * 3600)
                Check.expectTrue(renewed.made, "ended: made again")
                Check.expectFalse(try renewed.authority.der() == old.authority.der(), "a new root")
                Check.expectEqual(AuthorityStore.certificates(in: keychain).count, 1, "the old one gone")
                Check.expectEqual(AuthorityKey.find(in: keychain).count, 1)
                AuthorityKey.remove(from: keychain)
                Check.expectTrue(try AuthorityStore.load(in: keychain, machine: "Test Mac").made, "no key: made again")
                Check.expectEqual(AuthorityStore.certificates(in: keychain).count, 1)
            } catch {
                Check.expectTrue(false, "\(error)")
            }
        }
    }
}

import Foundation
import NetworkMonitorCore
import ServerDirectory

/// The Mac's addresses in the popover's Network view (#803).
func runInternetAddressTests() {
    /// A stand-in for the service and the Mac: what it answers, and how often
    /// it was asked.
    final class World {
        var addresses = ["192.168.1.20"]
        var own: String?
        var mayAsk = true
        var answer: String? = "fl=1\nh=one.one.one.one\nip=203.0.113.42\nts=1\nloc=DE\n"
        var asked = 0
        var lastURL: URL?

        func sources() -> InternetAddress.Sources {
            InternetAddress.Sources(
                addresses: { self.addresses },
                ownPublicAddress: { self.own },
                mayAsk: { self.mayAsk },
                fetch: { url, done in
                    self.asked += 1
                    self.lastURL = url
                    done(self.answer)
                },
                place: { address in
                    guard address == IPAddress("203.0.113.42") || address == IPAddress("198.51.100.7") else { return nil }
                    return ServerInfo(country: "DE",
                                      owner: NetworkOwner(asn: 3320, registeredName: "Deutsche Telekom AG",
                                                          company: Company(name: "Deutsche Telekom", isHost: false)))
                })
        }
    }

    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    Check.suite("Network — the Mac's addresses (#803)") {
        Check.test("this Mac's address shows, and nothing is asked while the lookup is off") {
            let world = World()
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-off"))
            addresses.networkDidChange(network: "home")
            settle()
            Check.expectEqual(addresses.local, "192.168.1.20")
            Check.expectEqual(addresses.state, .notAsked)
            Check.expectEqual(world.asked, 0)
        }

        Check.test("Show turns it on and asks Cloudflare once; the answer has its country and provider") {
            let world = World()
            let defaults = Check.defaults("address-show")
            let addresses = InternetAddress(sources: world.sources(), defaults: defaults)
            addresses.networkDidChange(network: "home")
            addresses.show()
            settle()
            Check.expectTrue(addresses.isEnabled)
            Check.expectEqual(world.asked, 1)
            Check.expectEqual(world.lastURL, InternetAddress.service)
            Check.expectEqual(addresses.state, .found(.init(address: "203.0.113.42", country: "DE",
                                                            provider: "Deutsche Telekom", isTheMacs: false)))
            Check.expectTrue(InternetAddress(sources: world.sources(), defaults: defaults).isEnabled,
                             "kept on after a restart")
        }

        Check.test("asked once per network, and again on the next") {
            let world = World()
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-per-network"))
            addresses.networkDidChange(network: "home")
            addresses.isEnabled = true
            settle()
            addresses.read()
            settle()
            Check.expectEqual(world.asked, 1, "reading the Mac's address asks nobody")
            addresses.networkDidChange(network: "home")
            settle()
            Check.expectEqual(world.asked, 1, "back on the same network after a blip: not again")
            addresses.networkDidChange(network: "office")
            settle()
            Check.expectEqual(world.asked, 2)
        }

        Check.test("never asked on a hotspot or in Low Data Mode") {
            let world = World()
            world.mayAsk = false
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-hotspot"))
            addresses.isEnabled = true
            addresses.networkDidChange(network: "home")
            settle()
            Check.expectEqual(world.asked, 0)
            Check.expectEqual(addresses.state, .notHere)
        }

        Check.test("switched off, nothing more is asked and the answer goes") {
            let world = World()
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-switched-off"))
            addresses.isEnabled = true
            settle()
            addresses.isEnabled = false
            addresses.networkDidChange(network: "home")
            settle()
            Check.expectEqual(world.asked, 1)
            Check.expectEqual(addresses.state, .notAsked)
        }

        Check.test("a Mac that holds its public address needs nobody to tell it") {
            let world = World()
            world.addresses = ["198.51.100.7", "2a02:810d::1"]
            world.own = "198.51.100.7"
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-public"))
            addresses.networkDidChange(network: "home")
            settle()
            Check.expectEqual(world.asked, 0)
            Check.expectEqual(addresses.state, .found(.init(address: "198.51.100.7", country: "DE",
                                                            provider: "Deutsche Telekom", isTheMacs: true)))
        }

        Check.test("an IPv6 address of the Mac's own is never taken for what websites see") {
            let world = World()
            world.addresses = ["192.168.1.20", "2a02:810d::1"]
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-v6"))
            addresses.isEnabled = true
            addresses.networkDidChange(network: "home")
            settle()
            Check.expectEqual(world.asked, 1)
            Check.expectEqual(addresses.state, .found(.init(address: "203.0.113.42", country: "DE",
                                                            provider: "Deutsche Telekom", isTheMacs: false)))
        }

        Check.test("switched off and on again on the same network, it asks again") {
            let world = World()
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-off-on"))
            addresses.networkDidChange(network: "home")
            addresses.isEnabled = true
            settle()
            addresses.isEnabled = false
            addresses.isEnabled = true
            settle()
            Check.expectEqual(world.asked, 2)
            Check.expectEqual(addresses.state, .found(.init(address: "203.0.113.42", country: "DE",
                                                            provider: "Deutsche Telekom", isTheMacs: false)))
        }

        Check.test("a network no longer taken for a hotspot is asked at once") {
            let world = World()
            world.mayAsk = false
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-verdict"))
            addresses.isEnabled = true
            addresses.networkDidChange(network: "phone")
            settle()
            Check.expectEqual(addresses.state, .notHere)
            world.mayAsk = true
            addresses.verdictDidChange()
            settle()
            Check.expectEqual(world.asked, 1)
            world.mayAsk = false
            addresses.verdictDidChange()
            Check.expectEqual(addresses.state, .notHere, "marked a hotspot: the answer goes")
        }

        Check.test("a new public address of the Mac's own shows when it's read again") {
            let world = World()
            world.own = "198.51.100.7"
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-lease"))
            addresses.networkDidChange(network: "office")
            settle()
            world.own = "203.0.113.42"
            addresses.read()
            settle()
            Check.expectEqual(addresses.state, .found(.init(address: "203.0.113.42", country: "DE",
                                                            provider: "Deutsche Telekom", isTheMacs: true)))
            Check.expectEqual(world.asked, 0)
        }

        Check.test("an answer that isn't an address is a failure, and Try Again asks again") {
            let world = World()
            world.answer = "<html>nope</html>"
            let addresses = InternetAddress(sources: world.sources(), defaults: Check.defaults("address-failed"))
            addresses.isEnabled = true
            settle()
            Check.expectEqual(addresses.state, .failed)
            world.answer = "ip=203.0.113.42"
            addresses.show()
            settle()
            Check.expectEqual(world.asked, 2)
            Check.expectEqual(addresses.state, .found(.init(address: "203.0.113.42", country: "DE",
                                                            provider: "Deutsche Telekom", isTheMacs: false)))
        }

        Check.test("the trace's ip line, and nothing else") {
            Check.expectEqual(InternetAddress.address(inTrace: "h=x\nip=2001:db8::1\nloc=US"), "2001:db8::1")
            Check.expectNil(InternetAddress.address(inTrace: "ip=not-an-address"))
            Check.expectNil(InternetAddress.address(inTrace: "loc=US"))
        }

        Check.test("where it is reads as country and provider") {
            let english = Locale(identifier: "en_US")
            Check.expectEqual(InternetAddress.Answer(address: "x", country: "DE", provider: "Deutsche Telekom",
                                                     isTheMacs: false).place(locale: english),
                              "🇩🇪 Germany · Deutsche Telekom")
            Check.expectEqual(InternetAddress.Answer(address: "x", country: nil, provider: "Ogero",
                                                     isTheMacs: false).place(locale: english), "Ogero")
            Check.expectNil(InternetAddress.Answer(address: "x", country: nil, provider: nil,
                                                   isTheMacs: false).place(locale: english))
        }
    }
}

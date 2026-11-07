import Foundation
import NetworkMonitorCore

func runConnectionStatusTests() {
    let ethernet = NetworkFingerprint.make(kind: .ethernet, gatewayMAC: "50:c7:bf:8a:94:93", interfaceName: "en7",
                                           isExpensive: false, isConstrained: false, gatewayIP: "192.168.1.1",
                                           interfaceDisplayName: "USB 10/100/1000 LAN")
    let wifi = NetworkFingerprint.make(kind: .wifi, gatewayMAC: "50:c7:bf:8a:94:93", interfaceName: "en0",
                                       isExpensive: false, isConstrained: false, gatewayIP: "192.168.1.1",
                                       interfaceDisplayName: "Wi-Fi", wifiName: "Home")
    let hotspot = NetworkFingerprint.make(kind: .hotspot, gatewayMAC: "9a:50:2e:c2:af:64", interfaceName: "en0",
                                          isExpensive: true, isConstrained: false, gatewayIP: "172.20.10.1",
                                          interfaceDisplayName: "Wi-Fi", wifiName: "Kevin's iPhone")
    let tether = NetworkFingerprint.make(kind: .hotspot, gatewayMAC: "9a:50:2e:c2:af:64", interfaceName: "en5",
                                         isExpensive: true, isConstrained: false, gatewayIP: "172.20.10.1",
                                         interfaceDisplayName: "iPhone USB")

    Check.suite("ConnectionStatus") {
        Check.test("names the connection in use") {
            let cable = ConnectionStatus.make(network: ethernet, verdict: .unmetered, name: nil)
            Check.expectEqual(cable.line, "Using Ethernet")
            Check.expectFalse(cable.isHighlighted)

            let home = ConnectionStatus.make(network: wifi, verdict: .unmetered, name: "Home")
            Check.expectEqual(home.line, "Using Wi-Fi · Home")
            Check.expectFalse(home.isHighlighted)
        }

        Check.test("a hotspot is called one, in orange, with its name") {
            let phone = ConnectionStatus.make(network: hotspot, verdict: .expensive, name: "Kevin's iPhone")
            Check.expectEqual(phone.line, "Using hotspot · Kevin's iPhone")
            Check.expectTrue(phone.isHighlighted)
            Check.expectEqual(ConnectionStatus.make(network: hotspot, verdict: .expensive, name: nil).line,
                              "Using hotspot")
        }

        Check.test("a tether goes by its interface's name") {
            Check.expectEqual(ConnectionStatus.make(network: tether, verdict: .tetherInterface, name: nil).line,
                              "Using hotspot · iPhone USB")
        }

        Check.test("a network marked as a hotspot is called one") {
            let marked = ConnectionStatus.make(network: wifi, verdict: .userMarked, name: "Hotel")
            Check.expectEqual(marked.line, "Using hotspot · Hotel")
            Check.expectTrue(marked.isHighlighted)
        }

        Check.test("a phone marked as not a hotspot isn't called one") {
            let cleared = ConnectionStatus.make(network: hotspot, verdict: .userCleared, name: "Kevin's iPhone")
            Check.expectEqual(cleared.line, "Using Wi-Fi · Kevin's iPhone")
            Check.expectFalse(cleared.isHighlighted)
        }

        Check.test("Low Data Mode doesn't make a network a hotspot") {
            let capped = ConnectionStatus.make(network: wifi, verdict: .constrained, name: "Home")
            Check.expectEqual(capped.line, "Using Wi-Fi · Home · Low Data Mode")
            Check.expectTrue(capped.isHighlighted)
        }

        Check.test("offline says so, whatever verdict is still held") {
            let none = ConnectionStatus.make(network: .offline, verdict: .expensive, name: nil)
            Check.expectEqual(none.line, "No connection")
            Check.expectFalse(none.isHighlighted)
        }
    }

    Check.suite("StandbyHotspot") {
        let phone = StandbyCandidate(networkID: "gw:9a:50:2e:c2:af:64",
                                     signals: .init(gatewayIP: "172.20.10.1", interfaceDisplayName: "Wi-Fi"),
                                     wifiName: "Kevin's iPhone", service: "Wi-Fi", isWiFi: true)
        let homeWiFi = StandbyCandidate(networkID: "gw:50:c7:bf:8a:94:00",
                                        signals: .init(gatewayIP: "192.168.1.1", interfaceDisplayName: "Wi-Fi"),
                                        wifiName: "Home", service: "Wi-Fi", isWiFi: true)

        func pick(_ candidates: [StandbyCandidate], inUse: NetworkFingerprint = ethernet, metered: Bool = false,
                  override: Bool? = nil, label: String? = nil) -> StandbyHotspot? {
            StandbyHotspots.pick(candidates, inUse: inUse, inUseIsMetered: metered,
                                 override: { _ in override }, label: { _ in label })
        }

        Check.test("finds a hotspot beside the connection in use") {
            Check.expectEqual(pick([phone]), StandbyHotspot(name: "Kevin's iPhone", service: "Wi-Fi"))
        }

        Check.test("ordinary Wi-Fi beside Ethernet isn't one") {
            Check.expectTrue(pick([homeWiFi]) == nil)
        }

        Check.test("looks past ordinary networks") {
            Check.expectEqual(pick([homeWiFi, phone])?.name, "Kevin's iPhone")
        }

        Check.test("respects what the person said about that network") {
            Check.expectTrue(pick([phone], override: false) == nil)
            Check.expectEqual(pick([homeWiFi], override: true)?.name, "Home")
        }

        Check.test("says nothing while already on a hotspot or offline") {
            Check.expectTrue(pick([phone], metered: true) == nil)
            Check.expectTrue(pick([phone], inUse: .offline) == nil)
        }

        Check.test("never reports the network in use as idle") {
            let same = StandbyCandidate(networkID: ethernet.id, signals: .init(gatewayIP: "172.20.10.1"))
            Check.expectTrue(pick([same]) == nil)
        }

        Check.test("the person's name beats the Wi-Fi name") {
            Check.expectEqual(pick([phone], label: "My phone")?.name, "My phone")
        }

        Check.test("with no name to read, says a hotspot, and a tether goes by its interface") {
            let unnamed = StandbyCandidate(networkID: phone.networkID, signals: phone.signals,
                                           service: "Wi-Fi", isWiFi: true)
            Check.expectEqual(pick([unnamed])?.message, "A hotspot is connected, but isn't being used")
            let usb = StandbyCandidate(networkID: "gw:aa", signals: .init(interfaceDisplayName: "iPhone USB"),
                                       service: "iPhone USB", isWiFi: false)
            Check.expectEqual(pick([usb])?.message, "iPhone USB is connected, but isn't being used")
        }

        Check.test("explains the way out for what's in use") {
            let standby = StandbyHotspot(name: "Kevin's iPhone", service: "Wi-Fi")
            let cable = ConnectionStatus.make(network: ethernet, verdict: .unmetered, name: nil)
            Check.expectEqual(standby.explanation(inUse: cable),
                              "Your Mac sends everything over the connection ranked highest in macOS, and that's "
                              + "Ethernet. To use the hotspot, unplug the cable, or move Wi-Fi above it in "
                              + "Network settings › Set Service Order.")
            Check.expectEqual(standby.rightNow(inUse: cable),
                              "You're on Ethernet. Kevin's iPhone is connected, but isn't being used.")

            let tethered = StandbyHotspot(name: "iPhone USB", service: "iPhone USB")
            let home = ConnectionStatus.make(network: wifi, verdict: .unmetered, name: "Home")
            Check.expectTrue(tethered.explanation(inUse: home)
                .contains("disconnect from that Wi-Fi network, or move iPhone USB above it"))
        }

        Check.test("reads links from configd's state") {
            let states: [String: Any] = [
                "State:/Network/Service/A/IPv4": ["InterfaceName": "en7", "Router": "192.168.1.1"],
                "State:/Network/Service/B/IPv4": ["InterfaceName": "en0", "Router": "172.20.10.1",
                                                  "ARPResolvedIPAddress": "172.20.10.1",
                                                  "ARPResolvedHardwareAddress": "9a:50:2e:c2:af:64"],
                "State:/Network/Service/C/IPv4": ["InterfaceName": "utun3", "Router": "10.0.0.1"],
                "State:/Network/Service/D/IPv4": ["InterfaceName": "en1"],
            ]
            let links = StandbyHotspots.links(besides: "en7", in: states)
            Check.expectEqual(links.map(\.interface), ["en0"])
            Check.expectEqual(links.first?.router, "172.20.10.1")
            Check.expectEqual(links.first?.routerMAC, "9a:50:2e:c2:af:64")
            Check.expectFalse(links.first?.androidSaysMetered ?? true)
        }

        Check.test("reads an Android phone's lease on a link not in use") {
            let states: [String: Any] = [
                "State:/Network/Service/B/IPv4": ["InterfaceName": "en0", "Router": "10.33.21.1"],
                "State:/Network/Service/B/DHCP": ["Option_43": AndroidTethering.vendorInfo],
            ]
            Check.expectTrue(StandbyHotspots.links(besides: "en7", in: states).first?.androidSaysMetered ?? false)
        }
    }
}

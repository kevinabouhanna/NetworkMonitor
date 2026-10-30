import FilterProtocol
import Foundation
import NetworkExtension
import NetworkMonitorCore
import ServerDirectory
import SystemExtensions

func runFilterTests() {
    Check.suite("Content filter — what it reports") {

        Check.test("reports survive the trip from the filter to the app") {
            let report = FlowReport(address: "52.112.0.1", port: 443, hostname: "teams.microsoft.com",
                                    pid: 321, time: Date(timeIntervalSince1970: 1_800_000_000))
            Check.expectEqual(FlowReport.decode(FlowReport.encode([report])), [report])
            Check.expectEqual(FlowReport.decode(Data("not json".utf8)), [])
        }

        // audit_token_t is eight 32-bit words; the process ID is the sixth.
        Check.test("reads the process ID from an audit token") {
            var words: [UInt32] = [1, 2, 3, 4, 5, 4242, 7, 8]
            let token = Data(bytes: &words, count: words.count * 4)
            Check.expectEqual(FlowReport.pid(fromAuditToken: token), 4242)
            Check.expectEqual(FlowReport.pid(fromAuditToken: Data([1, 2, 3])), 0)
            Check.expectEqual(FlowReport.pid(fromAuditToken: nil), 0)
        }

        Check.test("only NetworkMonitor's team may connect to the filter") {
            Check.expectTrue(FilterIdentity.appRequirement.contains("GRQKG7M8CL"))
            Check.expectTrue(FilterIdentity.machServiceName.hasPrefix(FilterIdentity.teamIdentifier + "."))
        }

        // #142: a name per build, under the app group, as both ends read it.
        Check.test("each build's filter has a service name of its own") {
            let name = FilterIdentity.machServiceName(build: "89")
            Check.expectEqual(name, "GRQKG7M8CL.com.kevinabouhanna.NetworkMonitor.Filter.89")
            Check.expectTrue(name.hasPrefix(FilterIdentity.appGroup + "."), "under the app group")
            Check.expectTrue(FilterIdentity.machServiceName(build: "89") != FilterIdentity.machServiceName(build: "90"))
            let info: [String: Any] = ["NetworkExtension": ["NEMachServiceName": name]]
            Check.expectEqual(FilterIdentity.machServiceName(inInfo: info), name)
            Check.expectEqual(FilterIdentity.machServiceName(inInfo: nil), FilterIdentity.machServiceName,
                              "a filter without a stamped name")
        }
    }

    Check.suite("Content filter — companies from server names") {

        func company(_ hostname: String) -> Company? { Company.named(byHostname: hostname) }

        // The point of #128: a name says whose server it is, wherever it's hosted.
        Check.test("a name says whose server it is") {
            Check.expectEqual(company("api.slack.com")?.name, "Slack")
            Check.expectEqual(company("edge-star-mini-shv-01.facebook.com")?.name, "Meta")
            Check.expectEqual(company("scontent.cdninstagram.com")?.name, "Meta")
            Check.expectEqual(company("www.googleapis.com")?.name, "Google")
            Check.expectEqual(company("api.figma.com")?.name, "Figma", "an unknown domain names itself")
            Check.expectEqual(company("api.figma.com")?.isHost, false)
            Check.expectEqual(company("dns.google")?.name, "Google", "a brand's own top-level domain")
            Check.expectEqual(company("http-intake.logs.us5.datadoghq.com")?.name, "Datadog")
            // Seen on Kevin's Mac in 1.14.0, each under a domain's name of its own.
            Check.expectEqual(company("slackb.com")?.name, "Slack")
            Check.expectEqual(company("x.raycast-releases.com")?.name, "Raycast")
            Check.expectEqual(company("a-cdn.claudeusercontent.com")?.name, "Anthropic")
            Check.expectEqual(company("proxy.googlezip.net")?.name, "Google")
        }

        Check.test("a host's own domain leaves it to the network's owner") {
            Check.expectNil(company("d2x8p0abc.cloudfront.net"))
            Check.expectNil(company("e1234.a.akamaiedge.net"))
            Check.expectNil(company("myapp.appspot.com"))
        }

        Check.test("addresses and bare words aren't names") {
            Check.expectNil(company("142.250.180.14"))
            Check.expectNil(company("localhost"))
        }

        Check.test("country domains keep their second level") {
            Check.expectEqual(company("www.bbc.co.uk")?.name, "Bbc")
        }

        Check.test("Connections uses the name over the network's owner") {
            let amazon = NetworkOwner(asn: 16509, registeredName: "Amazon.com, Inc.",
                                      company: Company(name: "Amazon", isHost: true))
            let usage = ServerUsage(appKey: "Slack", address: "3.65.102.105", bytesIn: 10, bytesOut: 0,
                                    firstSeen: Date(), appName: "Slack", name: "wss-primary.slack.com")
            let named = Connection(usage: usage, country: "DE", owner: amazon)
            let groups = ConnectionsReport.groups([named], by: .companies)
            Check.expectEqual(groups.first?.item.title, "Slack")
            Check.expectEqual(groups.first?.item.isHost, false)
            let server = groups.first?.sections.first { $0.dimension == .server }?.items.first
            Check.expectEqual(server?.title, "wss-primary.slack.com")
            Check.expectTrue(server?.subtitle?.contains("3.65.102.105") ?? false, "the address underneath")
            Check.expectEqual(ConnectionsReport.groups([named], by: .companies, search: "wss-primary").count, 1)
        }
    }

    Check.suite("Content filter — names in Usage History") {

        Check.test("a name the filter saw is stored with its server and read back") {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("filter-names-\(UUID().uuidString).sqlite")
            defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let now = Date(timeIntervalSince1970: 1_792_573_800)
            let history = UsageHistory(databaseURL: url, calendar: calendar)
            history.join(NetworkFingerprint(id: "A", kind: .wifi, gatewayMAC: "A", defaultLabel: "A",
                                            isExpensive: false, isConstrained: false),
                         label: "A", switched: false, now: now)
            let slack = AppIdentity(key: "Slack", displayName: "Slack", bundlePath: nil, isSystem: false)
            history.noteServerNames([("3.65.102.105", "wss-primary.slack.com")])
            history.recordApps([(slack, 10, 0)],
                               servers: ["Slack": ["3.65.102.105": ByteCounts(bytesIn: 10, bytesOut: 0)]], now: now)
            let day = HistoryPeriod(scale: .day, containing: now, calendar: calendar)
            Check.expectEqual(history.servers(in: day).first?.name, "wss-primary.slack.com")

            // A later name for the same address wins; reopening keeps it.
            history.noteServerNames([("3.65.102.105", "app.slack.com")])
            history.flush(now: now)
            let reopened = UsageHistory(databaseURL: url, calendar: calendar)
            Check.expectEqual(reopened.servers(in: day).first?.name, "app.slack.com")
        }
    }
}

func runSetupTests() {
    Check.suite("Welcome window and permissions (#134)") {

        Check.test("shown once, and only with something to offer") {
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .off, wifi: .asking))
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .on, wifi: .denied))
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .off, wifi: .allowed))
            Check.expectTrue(Welcome.shouldShow(shown: false, filter: .unavailable, wifi: .asking))
            Check.expectFalse(Welcome.shouldShow(shown: false, filter: .on, wifi: .allowed), "everything's on")
            Check.expectFalse(Welcome.shouldShow(shown: false, filter: .unavailable, wifi: .allowed))
            Check.expectFalse(Welcome.shouldShow(shown: true, filter: .off, wifi: .asking), "never twice")
        }

        // The point of #134: what you get, never how it works.
        Check.test("says what you get, in plain words") {
            let jargon = ["filter", "extension", "server", "ssid", "content", "permission", "dns", "socket"]
            for text in SetupCopy.plain {
                for word in jargon {
                    Check.expectFalse(text.lowercased().contains(word), "“\(word)” in: \(text)")
                }
            }
        }

        Check.test("a newer request isn't a failure, and no isn't an error") {
            let superseded = NSError(domain: OSSystemExtensionErrorDomain,
                                     code: OSSystemExtensionError.requestSuperseded.rawValue)
            Check.expectNil(FilterController.state(after: superseded))

            let outsideApplications = NSError(domain: OSSystemExtensionErrorDomain,
                                              code: OSSystemExtensionError.unsupportedParentBundleLocation.rawValue)
            Check.expectEqual(FilterController.state(after: outsideApplications), .needsApplicationsFolder)

            let declined = NSError(domain: NEFilterErrorDomain,
                                   code: NEFilterManagerError.configurationPermissionDenied.rawValue)
            let cancelled = NSError(domain: OSSystemExtensionErrorDomain,
                                    code: OSSystemExtensionError.requestCanceled.rawValue)
            for answer in [declined, cancelled] {
                let state = FilterController.state(after: answer)
                Check.expectNotNil(state)
                if case .failed = state { Check.expectTrue(false, "an answer shown as a failure") }
            }

            let broken = NSError(domain: OSSystemExtensionErrorDomain,
                                 code: OSSystemExtensionError.validationFailed.rawValue)
            if case .failed = FilterController.state(after: broken) {} else {
                Check.expectTrue(false, "a real failure is shown as one")
            }
        }
    }
}

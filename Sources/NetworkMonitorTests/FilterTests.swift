import FilterProtocol
import Foundation
import NetworkMonitorCore
import ServerDirectory

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

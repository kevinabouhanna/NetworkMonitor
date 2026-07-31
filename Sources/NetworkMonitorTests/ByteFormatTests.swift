import Foundation
import NetworkMonitorCore

func runByteFormatTests() {
    Check.suite("ByteFormat") {

        Check.test("raw bytes have no decimal") {
            Check.expectEqual(ByteFormat.bytes(0), "0 B")
            Check.expectEqual(ByteFormat.bytes(263), "263 B")
            Check.expectEqual(ByteFormat.bytes(1023), "1023 B")
        }

        // Spec boundaries: 1024-based steps.
        Check.test("unit boundaries") {
            Check.expectEqual(ByteFormat.bytes(1024), "1.0 KB")
            Check.expectEqual(ByteFormat.bytes(1024 * 1024), "1.0 MB")
            Check.expectEqual(ByteFormat.bytes(1024 * 1024 * 1024), "1.0 GB")
            Check.expectEqual(ByteFormat.bytes(1024 * 1024 * 1024 * 1024), "1.0 TB")
        }

        Check.test("spec example renders as 489.3 MB") {
            Check.expectEqual(ByteFormat.bytes(513_057_587), "489.3 MB")
        }

        // Real lifetime counters from the development machine.
        Check.test("large real-world values") {
            Check.expectEqual(ByteFormat.bytes(5_555_944_103), "5.2 GB")
            Check.expectEqual(ByteFormat.bytes(263_630_067), "251.4 MB")
        }

        Check.test("saturates instead of running off the unit table") {
            Check.expectTrue(ByteFormat.bytes(Int64.max).hasSuffix("PB"),
                             "got \(ByteFormat.bytes(Int64.max))")
        }

        Check.test("rate formatting") {
            Check.expectEqual(ByteFormat.rate(0), "0 B/s")
            // Sub-1 B/s is sampler noise, not a rate.
            Check.expectEqual(ByteFormat.rate(0.4), "0 B/s")
            Check.expectEqual(ByteFormat.rate(512), "512 B/s")
            Check.expectEqual(ByteFormat.rate(131_072), "128.0 KB/s")
        }

        // Constant character count across every magnitude AND every unit.
        Check.test("menu bar rate has a constant character count") {
            let expected = ByteFormat.menuBarNumberWidth + 1 + ByteFormat.menuBarUnitWidth
            for value in [0, 0.4, 1, 512, 999, 1024, 131_072, 1_048_576,
                          10_485_760, 117_440_512, 1_073_741_824,
                          1_099_511_627_776] as [Double] {
                let rendered = ByteFormat.menuBarRate(value)
                Check.expectEqual(rendered.count, expected,
                                  "‘\(rendered)’ must be \(expected) chars")
            }
        }

        // Three integer digits already fill the field; a decimal there would
        // widen the string and reintroduce jitter.
        // Two decimals where they fit, then one, then none — so the numeric
        // field stays exactly 5 characters at every magnitude.
        Check.test("menu bar precision degrades with magnitude") {
            Check.expectEqual(
                ByteFormat.menuBarRate(14.14 * 1024).trimmingCharacters(in: .whitespaces),
                "14.14 KB/s", "two decimals below 100")
            Check.expectEqual(
                ByteFormat.menuBarRate(1024 * 128).trimmingCharacters(in: .whitespaces),
                "128.0 KB/s", "one decimal at three digits")
            Check.expectEqual(
                ByteFormat.menuBarRate(0).trimmingCharacters(in: .whitespaces),
                "0.00 B/s", "idle")
        }

        // `%.1f` must not follow the user's locale — a comma decimal separator
        // would look broken next to a byte unit.
        Check.test("decimal separator is always a dot") {
            Check.expectTrue(ByteFormat.bytes(1536).contains("."))
            Check.expectFalse(ByteFormat.bytes(1536).contains(","))
        }
    }
}

func runGatewayProbeTests() {
    Check.suite("GatewayProbe") {

        // Verbatim `arp -n` output from the development machine.
        Check.test("parses arp output") {
            let output = "? (192.168.1.1) at 50:c7:bf:8a:94:93 on en0 ifscope [ethernet]"
            Check.expectEqual(GatewayProbe.parseARP(output), "50:c7:bf:8a:94:93")
        }

        // macOS prints MACs without leading zeros; normalising keeps a
        // network's bucket key stable.
        Check.test("normalises short octets") {
            let output = "? (10.0.0.1) at 0:1b:63:8:4:e6 on en0 ifscope [ethernet]"
            Check.expectEqual(GatewayProbe.parseARP(output), "00:1b:63:08:04:e6")
        }

        Check.test("ignores incomplete entries") {
            Check.expectNil(GatewayProbe.parseARP(
                "? (192.168.1.1) at (incomplete) on en0 ifscope [ethernet]"))
            Check.expectNil(GatewayProbe.parseARP("192.168.1.1 (192.168.1.1) -- no entry"))
            Check.expectNil(GatewayProbe.parseARP(""))
        }

        Check.test("uppercase is normalised") {
            let output = "? (192.168.1.1) at 50:C7:BF:8A:94:93 on en0 ifscope [ethernet]"
            Check.expectEqual(GatewayProbe.parseARP(output), "50:c7:bf:8a:94:93")
        }

        // Integration: this machine has a reachable default gateway.
        Check.test("resolves this machine's gateway MAC") {
            Check.expectNotNil(GatewayProbe.defaultGatewayIP(), "no default route found")
            if let mac = GatewayProbe.macAddress() {
                Check.expectEqual(mac.split(separator: ":").count, 6, "malformed MAC \(mac)")
            }
        }
    }
}

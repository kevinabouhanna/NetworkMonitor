import Foundation
import NetworkMonitorCore

/// Fixtures are verbatim `nettop` output captured on macOS 26.5.2 from
/// `nettop -P -x -d -L 0 -s 1 -J time,bytes_in,bytes_out`.
func runNettopParserTests() {
    Check.suite("NettopParser — row parsing") {

        Check.test("parses a standard row") {
            let row = NettopParser.parseRow("02:21:32.760799,mDNSResponder.501,7845,6862,")
            Check.expectEqual(row, NettopRow(pid: 501, processName: "mDNSResponder",
                                             bytesIn: 7845, bytesOut: 6862))
        }

        // nettop truncates names to the kernel's 15-char `p_comm` limit. The
        // truncated name survives as a display fallback; the pid is what matters.
        Check.test("parses a truncated name containing spaces") {
            let row = NettopParser.parseRow("02:21:32.760799,Google Chrome H.1578,4529465,414001,")
            Check.expectEqual(row?.processName, "Google Chrome H")
            Check.expectEqual(row?.pid, 1578)
        }

        // Names contain dots (`com.apple.WebKit`, `launchd.develop`), so the pid
        // must be split off at the LAST dot, not the first.
        Check.test("splits the pid at the last dot") {
            let row = NettopParser.parseRow("02:21:32.760799,com.apple.WebKit.12345,10,20,")
            Check.expectEqual(row?.processName, "com.apple.WebKit")
            Check.expectEqual(row?.pid, 12345)
        }

        // nettop does not quote CSV fields, so a comma in a process name would
        // break left-to-right indexing. Fields are read from the right instead.
        Check.test("survives a comma inside a process name") {
            let row = NettopParser.parseRow("02:21:32.760799,Weird,App.999,111,222,")
            Check.expectEqual(row?.pid, 999)
            Check.expectEqual(row?.bytesIn, 111)
            Check.expectEqual(row?.bytesOut, 222)
        }

        // Idle sockets emit empty numeric fields rather than zeros.
        Check.test("empty counters become zero") {
            let row = NettopParser.parseRow("02:21:32.760799,airportd.494,,,")
            Check.expectEqual(row?.pid, 494)
            Check.expectEqual(row?.bytesIn, 0)
            Check.expectEqual(row?.bytesOut, 0)
        }

        // `-P` is not passed, so these sub-rows are in every sample. Counting them
        // would double the parent process's traffic. They are carried on purpose:
        // the bytes they add to the stream are what keeps nettop's 16 KB pipe
        // buffer flushing every few seconds instead of every ~30.
        Check.test("rejects per-connection sub-rows") {
            Check.expectNil(NettopParser.parseRow(
                "02:21:32,tcp4 192.168.1.107:60282<->192.168.1.1:445,263,287,"))
            Check.expectNil(NettopParser.parseRow("02:21:32,udp4 *:*<->*:*,,,"))
        }

        // A whole sample of mixed rows must yield one entry per process and none
        // per socket, which is the invariant that makes dropping `-P` safe.
        Check.test("a mixed sample yields process rows only") {
            var parser = NettopParser()
            let sample = """
            time,,bytes_in,bytes_out,
            02:21:32,mDNSResponder.501,7845,6862,
            02:21:32,udp4 *:5353<->*:*,7845,6862,
            02:21:32,Google Chrome H.9312,4000,900,
            02:21:32,tcp4 10.0.0.2:51000<->142.250.0.1:443,4000,900,
            time,,bytes_in,bytes_out,
            02:21:33,mDNSResponder.501,10,20,
            02:21:33,udp4 *:5353<->*:*,10,20,
            time,,bytes_in,bytes_out,
            """
            // The trailing newline matters: `consume` only acts on completed lines,
            // and it is the *next* header that closes the sample before it.
            let samples = parser.consume(sample + "\n")
            // First sample is the cumulative priming one and is discarded.
            Check.expectEqual(samples.count, 1, "one delta sample should survive priming")
            Check.expectEqual(samples.first?.count, 1, "only the process row counts")
            Check.expectEqual(samples.first?.first?.pid, 501)
            Check.expectEqual(samples.first?.first?.bytesIn, 10)
        }

        Check.test("rejects malformed rows") {
            Check.expectNil(NettopParser.parseRow(""))
            Check.expectNil(NettopParser.parseRow("garbage"))
            Check.expectNil(NettopParser.parseRow("02:21:32,noPidHere,1,2,"))
        }

        Check.test("recognises both header forms") {
            Check.expectTrue(NettopParser.isHeader("time,,bytes_in,bytes_out,"))
            Check.expectTrue(NettopParser.isHeader(",bytes_in,bytes_out,"))
            Check.expectFalse(NettopParser.isHeader("02:21:32.760799,mDNSResponder.501,1,2,"))
        }
    }

    Check.suite("NettopParser — sample framing") {

        // The single most important behaviour in the app: nettop's first sample
        // is cumulative-since-process-start, not a delta. Counting it would
        // credit every process with all its traffic since boot — mDNSResponder
        // alone would arrive with 251 MB already on the clock.
        Check.test("discards the cumulative priming sample") {
            var parser = NettopParser()
            let stream = """
            time,,bytes_in,bytes_out,
            02:21:31.761125,mDNSResponder.501,263630067,238967705,
            time,,bytes_in,bytes_out,
            02:21:32.760799,mDNSResponder.501,7845,6862,
            time,,bytes_in,bytes_out,

            """
            let samples = parser.consume(stream)
            Check.expectEqual(samples.count, 1, "priming sample must be dropped")
            Check.expectEqual(samples.first?.first?.bytesIn, 7845)
        }

        // stdout arrives in arbitrary chunks; a row split mid-line must not be lost.
        Check.test("reassembles writes split mid-line") {
            var parser = NettopParser()
            Check.expectTrue(parser.consume("time,,bytes_in,bytes_out,\n").isEmpty)
            Check.expectTrue(parser.consume("02:21:31,mDNSResponder.501,100,200,\n").isEmpty)
            Check.expectTrue(parser.consume("time,,bytes_in,byt").isEmpty)
            Check.expectTrue(parser.consume("es_out,\n02:21:32,mDNSRespo").isEmpty)
            let samples = parser.consume("nder.501,7845,6862,\ntime,,bytes_in,bytes_out,\n")
            Check.expectEqual(samples.count, 1)
            Check.expectEqual(samples.first?.first?.bytesIn, 7845)
        }

        // After a restart the stream begins with a cumulative sample again.
        Check.test("restart discards the new priming sample") {
            var parser = NettopParser()
            _ = parser.consume("time,,a,b,\n02:21:31,proc.1,5,5,\ntime,,a,b,\n02:21:32,proc.1,7,7,\n")
            parser.resetForRestart()
            let samples = parser.consume("""
            time,,bytes_in,bytes_out,
            02:30:00,proc.1,999999,999999,
            time,,bytes_in,bytes_out,
            02:30:01,proc.1,42,42,
            time,,bytes_in,bytes_out,

            """)
            Check.expectEqual(samples.count, 1)
            Check.expectEqual(samples.first?.first?.bytesIn, 42,
                              "post-restart cumulative sample must be discarded")
        }

        Check.test("parses a multi-process sample in order") {
            var parser = NettopParser()
            _ = parser.consume("time,,bytes_in,bytes_out,\n02:21:31,proc.1,1,1,\n")
            let samples = parser.consume("""
            time,,bytes_in,bytes_out,
            02:21:32,Slack Helper.1532,168,162,
            02:21:32,Google Chrome H.1578,0,32,
            02:21:32,Claude Helper.63144,39,46,
            time,,bytes_in,bytes_out,

            """)
            Check.expectEqual(samples.count, 1)
            Check.expectEqual(samples.first?.count, 3)
            Check.expectEqual(samples.first?.map(\.pid) ?? [], [1532, 1578, 63144])
        }
    }
}

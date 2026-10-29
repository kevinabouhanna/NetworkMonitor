// swift-tools-version:5.9
//
// Tools version 5.9 is deliberate: it defaults to the Swift 5 language mode, so
// the package builds without Swift 6's strict-concurrency annotations while
// still compiling under the Swift 6.3 toolchain.
import PackageDescription

let package = Package(
    name: "NetworkMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        // Everything testable lives in NetworkMonitorCore. The executable is a
        // thin shell so `swift test` never has to link an NSApplication main().
        .target(
            name: "NetworkMonitorCore",
            dependencies: ["LowDataMode", "ServerDirectory"],
            path: "Sources/NetworkMonitorCore"
        ),
        .executableTarget(
            name: "NetworkMonitor",
            dependencies: ["NetworkMonitorCore"],
            path: "Sources/NetworkMonitor"
        ),
        // The privileged half of hotspot metering: the only part that runs as
        // root, and deliberately the smallest thing in the package. It links
        // nothing from NetworkMonitorCore — a root binary should not carry a
        // menu bar app's dependencies — and its whole vocabulary is seven verbs.
        // Pure Foundation, no dependencies, so both the root helper and the
        // test suite can use it. /etc/hosts is machine-wide infrastructure and
        // the code that edits it needs tests more than it needs to be inline.
        .target(
            name: "HostsFile",
            path: "Sources/HostsFile"
        ),
        // Reading interface flags and the helper's one-line report. Shared by
        // the root helper, which sets the flags, and the app, which checks them,
        // so the two cannot disagree about what either one means. Pure
        // Foundation for the same reason as HostsFile.
        .target(
            name: "LowDataMode",
            path: "Sources/LowDataMode"
        ),
        .executableTarget(
            name: "NetworkMonitorHelper",
            dependencies: ["HostsFile", "LowDataMode"],
            path: "Sources/NetworkMonitorHelper"
        ),
        // Where a server is and whose network it belongs to, from DB-IP's data
        // shipped in Resources/Geo. Pure Foundation: the app needs it now, and
        // the content filter will later, without the app's frameworks.
        .target(
            name: "ServerDirectory",
            path: "Sources/ServerDirectory"
        ),
        // Converts DB-IP's CSVs into Resources/Geo. Run by Scripts/geodata.sh;
        // never part of the app.
        .executableTarget(
            name: "GeoDataBuilder",
            dependencies: ["ServerDirectory"],
            path: "Sources/GeoDataBuilder"
        ),
        // Converts Natural Earth's countries into Resources/Geo/world.bin, the
        // Connections map. Run by Scripts/mapdata.sh; never part of the app.
        .executableTarget(
            name: "MapDataBuilder",
            dependencies: ["ServerDirectory"],
            path: "Sources/MapDataBuilder"
        ),
        // An executable, not a .testTarget: neither XCTest nor swift-testing is
        // available with Command Line Tools alone (both ship inside Xcode), so
        // `swift test` cannot run here. Run with `swift run NetworkMonitorTests`.
        .executableTarget(
            name: "NetworkMonitorTests",
            dependencies: ["NetworkMonitorCore", "HostsFile", "LowDataMode", "ServerDirectory"],
            path: "Sources/NetworkMonitorTests"
        ),
    ]
)

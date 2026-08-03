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
        // menu bar app's dependencies — and its whole vocabulary is four verbs.
        // Pure Foundation, no dependencies, so both the root helper and the
        // test suite can use it. /etc/hosts is machine-wide infrastructure and
        // the code that edits it needs tests more than it needs to be inline.
        .target(
            name: "HostsFile",
            path: "Sources/HostsFile"
        ),
        .executableTarget(
            name: "NetworkMonitorHelper",
            dependencies: ["HostsFile"],
            path: "Sources/NetworkMonitorHelper"
        ),
        // An executable, not a .testTarget: neither XCTest nor swift-testing is
        // available with Command Line Tools alone (both ship inside Xcode), so
        // `swift test` cannot run here. Run with `swift run NetworkMonitorTests`.
        .executableTarget(
            name: "NetworkMonitorTests",
            dependencies: ["NetworkMonitorCore", "HostsFile"],
            path: "Sources/NetworkMonitorTests"
        ),
    ]
)

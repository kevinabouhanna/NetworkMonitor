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
        // An executable, not a .testTarget: neither XCTest nor swift-testing is
        // available with Command Line Tools alone (both ship inside Xcode), so
        // `swift test` cannot run here. Run with `swift run NetworkMonitorTests`.
        .executableTarget(
            name: "NetworkMonitorTests",
            dependencies: ["NetworkMonitorCore"],
            path: "Sources/NetworkMonitorTests"
        ),
    ]
)

import Foundation

// Run with: swift run NetworkMonitorTests
//
// Exits non-zero on any failure, so this works as a pre-commit or CI gate.

print("NetworkMonitor test suite")
print(String(repeating: "─", count: 62))

runByteFormatTests()
runMenuBarTitleTests()
runTrackingModeTests()
runLoginItemTests()
runGatewayProbeTests()
runNettopParserTests()
runNettopStreamIntegrationTests()
runInterfaceClassificationTests()
runInterfaceDeltaTrackerTests()
runRateSmootherTests()
runAppIdentityTests()
runUsageStoreTests()
runUsageRowPartitionTests()
runRowOrderTests()
runNetworkFingerprintTests()

exit(Check.summarize())

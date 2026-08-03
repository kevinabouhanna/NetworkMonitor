import Foundation

// Run with: swift run NetworkMonitorTests
//
// Exits non-zero on any failure, so this works as a pre-commit or CI gate.

print("NetworkMonitor test suite")
print(String(repeating: "─", count: 62))

runByteFormatTests()
runMenuBarTitleTests()
runPowerProfileTests()
runLoginItemTests()
runGatewayProbeTests()
runNettopParserTests()
runTrafficScopeTests()
runNettopStreamIntegrationTests()
runInterfaceClassificationTests()
runInterfaceDeltaTrackerTests()
runRateSmootherTests()
runAppIdentityTests()
runUsageStoreTests()
runUsageRowPartitionTests()
runRowOrderTests()
runPopoverMetricsTests()
runNetworkFingerprintTests()
runMeteredHeuristicTests()
runSuppressionJournalTests()
runPreferenceSuppressorTests()
runConfigFileSuppressorTests()
runMeteringControllerTests()
runHostsFileTests()
runJSONConfigEditTests()
runSuppressedValueTests()

exit(Check.summarize())

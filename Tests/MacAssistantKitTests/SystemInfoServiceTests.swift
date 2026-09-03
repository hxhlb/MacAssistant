import XCTest
import IOKit.ps
@testable import MacAssistantKit

final class SystemInfoServiceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testHostVMStatisticsMatchesActivityMonitorKeys() throws {
        let stats = try XCTUnwrap(MemoryService.hostVMStatistics())
        XCTAssertGreaterThan(stats.pageSize, 0)
        XCTAssertGreaterThan(stats.pages["Anonymous pages"] ?? 0, 0)
        let used = MemoryService.usedBytes(pages: stats.pages, pageSize: stats.pageSize)
        let physical = ProcessInfo.processInfo.physicalMemory
        XCTAssertLessThanOrEqual(used, physical)
        XCTAssertGreaterThan(used, 0)
    }

    func testSnapshotDoesNotNeedExternalProcesses() {
        let snapshot = SystemInfoService.snapshot()
        XCTAssertFalse(snapshot.items.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.memoryUsedFraction, 0)
        XCTAssertLessThanOrEqual(snapshot.memoryUsedFraction, 1)
        XCTAssertFalse(snapshot.memoryUsedText.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.diskUsedFraction, 0)
        XCTAssertLessThanOrEqual(snapshot.diskUsedFraction, 1)
    }

    func testMemoryUsageUsesHostStatistics() {
        let total = ProcessInfo.processInfo.physicalMemory
        let usage = SystemInfoService.memoryUsage(total: total)
        XCTAssertLessThanOrEqual(usage.used, total)
        XCTAssertEqual(usage.used + usage.free, total)
        XCTAssertGreaterThan(usage.used, 0)
    }

    func testBatteryParserReadsInternalBatteryDescription() {
        let charging = SystemInfoService.battery(from: [[
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 80,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSIsChargingKey as String: true
        ]])
        XCTAssertEqual(charging.level, 0.8)
        XCTAssertEqual(charging.state, "充电中")

        let discharging = SystemInfoService.battery(from: [[
            kIOPSTypeKey as String: kIOPSInternalBatteryType as String,
            kIOPSCurrentCapacityKey as String: 40,
            kIOPSMaxCapacityKey as String: 100,
            kIOPSPowerSourceStateKey as String: kIOPSBatteryPowerValue as String
        ]])
        XCTAssertEqual(discharging.level, 0.4)
        XCTAssertEqual(discharging.state, "放电中")

        let ignored = SystemInfoService.battery(from: [[
            kIOPSTypeKey as String: "UPS",
            kIOPSCurrentCapacityKey as String: 10,
            kIOPSMaxCapacityKey as String: 100
        ]])
        XCTAssertNil(ignored.level)
        XCTAssertNil(ignored.state)
    }

    func testSwapUsedBytesIsReadable() {
        XCTAssertGreaterThanOrEqual(MemoryService.swapUsedBytes(), 0)
    }
}

import XCTest
@testable import MacAssistantKit

final class MemoryServiceTests: XCTestCase {
    /// 断言里写死了中文文案,不固定语言的话在英文系统上会失败。
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testParseVMStatUsesReportedPageSize() {
        let text = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free: 100.
        Pages active: 200.
        Pages occupied by compressor: 30.
        File-backed pages: 40.
        """
        let result = MemoryService.parseVMStat(text)
        XCTAssertEqual(result.pageSize, 16_384)
        XCTAssertEqual(result.pages["Pages free"], 100)
        XCTAssertEqual(result.pages["Pages occupied by compressor"], 30)
    }

    func testUsedBytesMatchesActivityMonitorMethodology() {
        // 真实机器采样：24GB 物理内存，free+speculative 仅约 112MB。
        let text = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                3730.
        Pages active:                            568577.
        Pages inactive:                          564806.
        Pages speculative:                         3436.
        Pages wired down:                        315087.
        Pages purgeable:                          25062.
        File-backed pages:                       210276.
        Anonymous pages:                         926543.
        Pages occupied by compressor:             57520.
        """
        let parsed = MemoryService.parseVMStat(text)
        // 已用 = 匿名 − 可清除 + 联动 + 压缩 = 1_274_088 页 ≈ 19.4GB，
        // 而不是“物理内存 − 空闲页” ≈ 23.9GB（那会让已用永远接近 100%）。
        XCTAssertEqual(
            MemoryService.usedBytes(pages: parsed.pages, pageSize: parsed.pageSize),
            1_274_088 * 16_384
        )
        // 已缓存文件只计文件页，不再把可清除页加进去。
        XCTAssertEqual(
            MemoryService.cachedFilesBytes(pages: parsed.pages, pageSize: parsed.pageSize),
            210_276 * 16_384
        )
    }

    func testUsedBytesIgnoresFileCacheAndClampsPurgeable() {
        // 大量文件缓存不应计入已用；purgeable 大于匿名页时做饱和处理而不是下溢。
        let pages: [String: UInt64] = [
            "Anonymous pages": 100,
            "Pages purgeable": 300,
            "Pages wired down": 50,
            "Pages occupied by compressor": 20,
            "File-backed pages": 100_000,
            "Pages free": 10
        ]
        XCTAssertEqual(MemoryService.usedBytes(pages: pages, pageSize: 16_384), 70 * 16_384)
        XCTAssertEqual(MemoryService.cachedFilesBytes(pages: pages, pageSize: 16_384), 100_000 * 16_384)
    }

    func testParseSwapAndPressure() {
        XCTAssertEqual(
            MemoryService.parseSwapUsage("total = 4096.00M  used = 1536.50M  free = 2559.50M"),
            1_611_137_024
        )
        XCTAssertEqual(
            MemoryService.parsePressureFreePercent("System-wide memory free percentage: 43%"),
            43
        )
        XCTAssertEqual(MemoryService.pressureLevel(statusLevel: 0), .healthy)
        XCTAssertEqual(MemoryService.pressureLevel(statusLevel: 1), .warning)
        XCTAssertEqual(MemoryService.pressureLevel(statusLevel: 2), .critical)
        XCTAssertEqual(MemoryService.pressureLevel(statusLevel: 4), .critical)
        XCTAssertEqual(MemoryService.pressureLevel(statusLevel: nil), .unknown)
    }

    func testSnapshotUsedFractionMatchesSystemUsedNotFreePercent() {
        let snapshot = MemorySnapshot(
            physical: 24 * 1_024 * 1_024 * 1_024,
            used: 18_750_000_000,
            cached: 3_690_000_000,
            compressed: 930_000_000,
            swapUsed: 24_500_000_000,
            pressureFreePercent: 78,
            pressureLevel: .warning
        )
        XCTAssertEqual(snapshot.usedPercent, 73)
        XCTAssertGreaterThan(snapshot.usedFraction, 0.7)
        // free% 不能再当进度条：78% 可用会画成 22%，和系统已用相反。
        XCTAssertNotEqual(snapshot.usedPercent, 100 - (snapshot.pressureFreePercent ?? 0))
    }

    func testHostVMStatisticsFeedsUsedBytesWithoutShell() throws {
        let stats = try XCTUnwrap(MemoryService.hostVMStatistics())
        XCTAssertGreaterThan(stats.pageSize, 0)
        let used = MemoryService.usedBytes(pages: stats.pages, pageSize: stats.pageSize)
        XCTAssertGreaterThan(used, 0)
        XCTAssertLessThanOrEqual(used, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThanOrEqual(MemoryService.swapUsedBytes(), 0)
    }

    func testMemorySnapshotUsesHostStatistics() throws {
        let snapshot = try MemoryService.snapshot()
        XCTAssertGreaterThan(snapshot.physical, 0)
        XCTAssertLessThanOrEqual(snapshot.used, snapshot.physical)
        XCTAssertGreaterThan(snapshot.used, 0)
    }

    func testMemoryStatusPressureLevelIsReadable() {
        let level = MemoryService.memoryStatusPressureLevel()
        XCTAssertNotNil(level)
        if let level {
            XCTAssertGreaterThanOrEqual(level, 0)
        }
    }

    func testParsePSSortsRSSAndFiltersUser() {
        let text = """
          100  501  2048 /Applications/A.app/Contents/MacOS/A
          101    0 99999 /usr/libexec/system
          102  501  4096 /Applications/B App.app/Contents/MacOS/B App
          103  501     0 /Applications/IDA Professional 9.4.app/Contents/MacOS/ida
        """
        let processes = MemoryService.parsePS(text, currentUserID: 501)
        XCTAssertEqual(processes.map(\.pid), [102, 100, 103])
        XCTAssertEqual(processes.first?.rssBytes, 4_194_304)
        XCTAssertEqual(processes.first?.name, "B App")
        XCTAssertEqual(processes.last?.rssBytes, 0)
        XCTAssertEqual(processes.last?.name, "ida")
    }

    func testSortPrefersFootprintOverRSS() {
        let ida = ProcessMemoryInfo(
            pid: 55951,
            userID: 501,
            rssBytes: 48 * 1_024 * 1_024,
            executablePath: "/Applications/IDA Professional 9.4.app/Contents/MacOS/ida",
            footprintBytes: 11 * 1_024 * 1_024 * 1_024,
            displayName: "IDA Professional 9.4"
        )
        let telegram = ProcessMemoryInfo(
            pid: 693,
            userID: 501,
            rssBytes: 238 * 1_024 * 1_024,
            executablePath: "/Applications/Telegram.app/Contents/MacOS/Telegram",
            footprintBytes: 2 * 1_024 * 1_024 * 1_024
        )
        XCTAssertEqual(ida.memoryBytes, 11 * 1_024 * 1_024 * 1_024)
        XCTAssertTrue(MemoryService.isHigherMemoryUsage(ida, telegram))
        XCTAssertEqual([telegram, ida].sorted(by: MemoryService.isHigherMemoryUsage).map(\.pid), [55951, 693])
    }

    func testProcessSearchMatchesAppNamePathAndPID() {
        let process = ProcessMemoryInfo(
            pid: 55951,
            userID: 501,
            rssBytes: 48 * 1_024 * 1_024,
            executablePath: "/Applications/IDA Professional 9.4.app/Contents/MacOS/ida",
            footprintBytes: 11 * 1_024 * 1_024 * 1_024,
            displayName: "IDA Professional 9.4"
        )
        XCTAssertTrue(process.matches("IDA"))
        XCTAssertTrue(process.matches("ida professional"))
        XCTAssertTrue(process.matches("9.4"))
        XCTAssertTrue(process.matches("55951"))
        XCTAssertTrue(process.matches("ida"))
        XCTAssertFalse(process.matches("ghidra"))
    }

    func testDisplayNameUsesAppFolderWhenPlistMatchesBinary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MADisplayName-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("IDA Professional 9.4.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleName": "ida",
            "CFBundleExecutable": "ida"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let path = app.appendingPathComponent("Contents/MacOS/ida").path
        XCTAssertEqual(
            ProcessDisplayNameResolver.displayName(executablePath: path),
            "IDA Professional 9.4"
        )
        try? FileManager.default.removeItem(at: root)
    }

    func testDisplayNameKeepsLocalizedBundleName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MADisplayName-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("WeChat.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleDisplayName": "微信",
            "CFBundleName": "WeChat"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        XCTAssertEqual(
            ProcessDisplayNameResolver.displayName(
                executablePath: app.appendingPathComponent("Contents/MacOS/WeChat").path
            ),
            "微信"
        )
        try? FileManager.default.removeItem(at: root)
    }

    func testCurrentProcessFootprintIsReadable() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let footprint = MemoryService.processMemoryFootprint(pid: pid)
        XCTAssertNotNil(footprint)
        XCTAssertGreaterThan(footprint ?? 0, 0)
        XCTAssertNil(MemoryService.processMemoryFootprint(pid: -1))
    }

    func testApplicationBundleResolverFindsOwningApp() {
        XCTAssertEqual(
            ProcessApplicationResolver.applicationBundlePath(
                forExecutablePath: "/Applications/Telegram.app/Contents/MacOS/Telegram"
            ),
            "/Applications/Telegram.app"
        )
    }

    func testApplicationBundleResolverMapsNestedHelperToOutermostHost() {
        let path = "/Applications/Cursor.app/Contents/Frameworks/"
            + "Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)"
        XCTAssertEqual(
            ProcessApplicationResolver.applicationBundlePath(
                forExecutablePath: path
            ),
            "/Applications/Cursor.app"
        )
        XCTAssertEqual(
            ProcessApplicationResolver.applicationBundlePaths(forExecutablePath: path),
            [
                "/Applications/Cursor.app",
                "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app"
            ]
        )
    }

    func testApplicationBundleResolverFallsBackForNonAppExecutable() {
        XCTAssertNil(
            ProcessApplicationResolver.applicationBundlePath(
                forExecutablePath: "/usr/libexec/exampled"
            )
        )
    }

    func testProcessIconCacheKeyDeduplicatesProcessesFromTheSameApp() {
        let key = ProcessIconCacheKey(pid: 42, bundlePath: "/Applications/A.app")
        XCTAssertEqual(key, ProcessIconCacheKey(pid: 43, bundlePath: "/Applications/A.app"))
        XCTAssertNotEqual(key, ProcessIconCacheKey(pid: 42, bundlePath: "/Applications/B.app"))
        XCTAssertNotEqual(
            ProcessIconCacheKey(pid: 42, bundlePath: nil),
            ProcessIconCacheKey(pid: 43, bundlePath: nil)
        )
    }

    func testProcPIDPathResolvesCurrentProcessWithoutAffectingFallbackCallers() {
        let path = MemoryService.processExecutablePath(
            pid: ProcessInfo.processInfo.processIdentifier
        )
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.hasPrefix("/") == true)
        XCTAssertNil(MemoryService.processExecutablePath(pid: -1))
    }

    func testPIDProtectionRejectsInvalidSelfAndCriticalProcesses() {
        XCTAssertThrowsError(try MemoryService.validatePID(1, processName: "launchd", ownPID: 500))
        XCTAssertThrowsError(try MemoryService.validatePID(500, processName: "MacAssistant", ownPID: 500))
        XCTAssertThrowsError(try MemoryService.validatePID(88, processName: "WindowServer", ownPID: 500))
        XCTAssertNoThrow(try MemoryService.validatePID(999, processName: "Example", ownPID: 500))
    }

    func testByteFormattingIsNonEmpty() {
        XCTAssertFalse(MemoryService.formatBytes(1_073_741_824).isEmpty)
        // 24 GiB 机器：活动监视器写 24 GB（中间可能是窄空格），不能用文件容量的 25.77 GB。
        let physical = MemoryService.formatBytes(25_769_803_776)
        XCTAssertTrue(physical.contains("24"), physical)
        XCTAssertTrue(physical.contains("GB"), physical)
        XCTAssertFalse(physical.contains("25.77"), physical)
    }

    func testPurgeIsDeveloperFileCacheOperationNotMemoryRelease() {
        let operation = MemoryService.purgeOperation
        XCTAssertEqual(operation.kind, .developerFileCacheBenchmark)
        XCTAssertTrue(operation.title.contains("文件缓存"))
        XCTAssertTrue(operation.explanation.contains("匿名内存"))
        XCTAssertTrue(operation.explanation.contains("不保证提速"))
        XCTAssertFalse(operation.title.contains("释放内存"))
        XCTAssertFalse(operation.explanation.contains("一键释放"))
    }

    func testProductLinksAreExact() {
        XCTAssertEqual(ProductLinks.github.absoluteString, "https://github.com/iosrxwy/MacAssistant")
        XCTAssertEqual(ProductLinks.twitter.absoluteString, "https://x.com/iOSRXWY")
        XCTAssertEqual(ProductLinks.releaseChannel.absoluteString, "https://t.me/iosrxwy")
        XCTAssertEqual(ProductLinks.altSignProject.absoluteString, "https://github.com/rileytestut/AltSign")
        XCTAssertEqual(ProductLinks.altStoreGitHub.absoluteString, "https://github.com/altstoreio/AltStore")
    }
}

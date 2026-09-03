import XCTest
@testable import MacAssistantKit

final class InjectionProgressLogTests: XCTestCase {
    private var savedOverride: AppLanguage?

    override func setUp() {
        super.setUp()
        savedOverride = LocalizationSettings.override
        LocalizationSettings.override = .simplifiedChinese
    }

    override func tearDown() {
        LocalizationSettings.override = savedOverride
        super.tearDown()
    }

    func testBoxedLinesMatchInjectipaWording() {
        XCTAssertEqual(InjectionProgressLog.unzipStart(), ">>> 解压IPA文件 <<<")
        XCTAssertEqual(InjectionProgressLog.unzipProgress(100), ">>> 当前解压进度(100%) <<<")
        XCTAssertEqual(InjectionProgressLog.unzipSucceeded(), ">>> 解压IPA文件成功 <<<")
        XCTAssertEqual(
            InjectionProgressLog.copyDylibSucceeded("MMlibAntiDetect.dylib"),
            ">>> 拷贝(MMlibAntiDetect.dylib)文件成功 <<<"
        )
        XCTAssertEqual(
            InjectionProgressLog.injectStart("MMlibAntiDetect.dylib"),
            ">>> 注入(MMlibAntiDetect.dylib) <<<"
        )
        XCTAssertEqual(
            InjectionProgressLog.injectSucceeded("MMlibAntiDetect.dylib"),
            ">>> 注入(MMlibAntiDetect.dylib)成功 <<<"
        )
        XCTAssertEqual(
            InjectionProgressLog.discoveredDependencies("WCRefine.dylib"),
            ">>> 发现(WCRefine.dylib)包含依赖 <<<"
        )
        XCTAssertEqual(
            InjectionProgressLog.rewrittenDependencies("WCRefine.dylib"),
            ">>> 修改(WCRefine.dylib)依赖成功 <<<"
        )
        XCTAssertEqual(InjectionProgressLog.removedPlugIns(), ">>> 删除小组件 <<<")
        XCTAssertEqual(InjectionProgressLog.removedWatch(), ">>> 删除手表组件 <<<")
        XCTAssertEqual(InjectionProgressLog.fileSharingEnabled(), ">>> 开启文件共享权限 <<<")
        XCTAssertEqual(
            InjectionProgressLog.assetsCarRemoved(appName: "WeChat.app", rendition: "AppIcon_1024_dark.png"),
            ">>> 是WeChat.app删除Assets.car中AppIcon_1024_dark.png <<<"
        )
        XCTAssertEqual(
            InjectionProgressLog.assetsCarRemoved(appName: "WeChat.app", rendition: "AppIcon_1024_tinted.png"),
            ">>> 是WeChat.app删除Assets.car中AppIcon_1024_tinted.png <<<"
        )
        XCTAssertEqual(InjectionProgressLog.zipStart(), ">>> 压缩注入工程 <<<")
        XCTAssertEqual(InjectionProgressLog.zipProgress(100), ">>> 当前压缩进度(100%) <<<")
        let ipa = "/Users/junlin/Documents/injectipa/微信_8.0.75_@com.tencent.xin.ipa"
        XCTAssertEqual(
            InjectionProgressLog.zipSucceeded(ipa),
            ">>> 压缩IPA文件成功 \(ipa) <<<"
        )
        XCTAssertEqual(InjectionProgressLog.clearedCache(), ">>> 清除工程缓存 <<<")
    }

    func testExecuteIPAStreamsUnzipCopyInjectZipAndCleanup() throws {
        for tool in [ExternalTool.clang, .zip, .unzip, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "progress-ipa")
        defer { try? FileManager.default.removeItem(at: root) }

        let ipaRoot = root.appendingPathComponent("ipaRoot")
        let app = ipaRoot.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(to: app)

        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let main = app.appendingPathComponent("Demo")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", main.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let plugin = root.appendingPathComponent("MMlibAntiDetect.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let ipa = root.appendingPathComponent("Demo.ipa")
        XCTAssertTrue(try ExternalTool.zip.run(
            ["-qry", ipa.path, "Payload"],
            currentDirectory: ipaRoot
        ).succeeded)

        let output = root.appendingPathComponent("Demo.injected.ipa")
        let streamed = LogCollector()
        let result = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: .ipa(ipa),
                items: [InjectionItem(dylibURL: plugin)],
                metadata: InjectionMetadataChanges(enableFileSharing: false),
                signing: .none
            ),
            outputURL: output,
            progress: { streamed.append($0) }
        )

        XCTAssertEqual(streamed.snapshot, result.log)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        assertContainsInOrder(result.log, [
            InjectionProgressLog.unzipStart(),
            InjectionProgressLog.unzipProgress(100),
            InjectionProgressLog.unzipSucceeded(),
            InjectionProgressLog.copyDylibSucceeded("MMlibAntiDetect.dylib"),
            InjectionProgressLog.injectStart("MMlibAntiDetect.dylib"),
            InjectionProgressLog.injectSucceeded("MMlibAntiDetect.dylib"),
            InjectionProgressLog.zipStart(),
            InjectionProgressLog.zipProgress(100),
            InjectionProgressLog.zipSucceeded(output.path),
            InjectionProgressLog.clearedCache()
        ])
        XCTAssertFalse(result.log.contains(InjectionProgressLog.removedPlugIns()))
        XCTAssertFalse(result.log.contains(InjectionProgressLog.removedWatch()))
        XCTAssertFalse(result.log.contains(InjectionProgressLog.fileSharingEnabled()))
        XCTAssertFalse(result.log.contains { $0.contains("删除Assets.car") })
        XCTAssertFalse(result.log.contains(InjectionProgressLog.discoveredDependencies("MMlibAntiDetect.dylib")))
    }

    /// 大型 IPA 的打包完成后不能再依赖一次全量解包。这里在归档结构校验完成时
    /// 占住旧实现使用的 `final-audit` 路径：若执行器仍尝试第二次展开整包，流程会失败。
    func testExecuteIPADoesNotRequireSecondFullExtractionAfterArchiveValidation() throws {
        for tool in [ExternalTool.clang, .zip, .unzip, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "progress-no-second-unzip")
        defer { try? FileManager.default.removeItem(at: root) }

        let ipaRoot = root.appendingPathComponent("ipaRoot")
        let app = ipaRoot.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePlist(to: app)

        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let main = app.appendingPathComponent("Demo")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", main.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let plugin = root.appendingPathComponent("Plugin.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let ipa = root.appendingPathComponent("Demo.ipa")
        XCTAssertTrue(try ExternalTool.zip.run(
            ["-qry", ipa.path, "Payload"],
            currentDirectory: ipaRoot
        ).succeeded)

        let blocker = try FinalAuditExtractionBlocker()
        let output = root.appendingPathComponent("Demo.injected.ipa")
        let result = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: .ipa(ipa),
                items: [InjectionItem(dylibURL: plugin)],
                metadata: InjectionMetadataChanges(enableFileSharing: false),
                signing: .none
            ),
            outputURL: output,
            progress: { line in
                if line == InjectionProgressLog.zipProgress(100) {
                    blocker.blockFinalAuditExtraction()
                }
            }
        )

        XCTAssertTrue(blocker.didBlock)
        XCTAssertTrue(result.audit.passed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testExecuteLogsComponentRemovalAndRewrittenDependenciesOnlyWhenDone() throws {
        for tool in [ExternalTool.clang, .otool, .installNameTool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "progress-rewrite")
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root.appendingPathComponent("WeChat.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("PlugIns"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Watch"),
            withIntermediateDirectories: true
        )
        try writePlist(to: app, executable: "WeChat")

        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let main = app.appendingPathComponent("WeChat")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", main.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let plugin = root.appendingPathComponent("WCRefine.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        _ = try DylibInjector.inject(
            dylibPath: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            intoFileAt: plugin,
            stripCodeSignature: true
        )

        let output = root.appendingPathComponent("Result.app")
        let streamed = LogCollector()
        let result = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: .app(app),
                items: [InjectionItem(dylibURL: plugin)],
                metadata: InjectionMetadataChanges(enableFileSharing: true),
                components: InjectionComponentPolicy(
                    watch: .remove,
                    plugIns: .remove,
                    destructiveRemovalConfirmed: true
                ),
                signing: .none
            ),
            outputURL: output,
            progress: { streamed.append($0) }
        )

        XCTAssertEqual(streamed.snapshot, result.log)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("PlugIns").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("Watch").path))
        let embedded = output.appendingPathComponent("Frameworks/WCRefine.dylib")
        let deps = try DylibService.dependencies(fileAt: embedded).map(\.path)
        XCTAssertTrue(deps.contains("@loader_path/libsubstrate.dylib"))
        XCTAssertFalse(deps.contains("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Frameworks/libsubstrate.dylib").path
        ))
        let mainLoads = try DylibInjector.loadedDylibPaths(fileAt: output.appendingPathComponent("WeChat"))
        XCTAssertFalse(mainLoads.contains { $0.hasSuffix("libsubstrate.dylib") })

        assertContainsInOrder(result.log, [
            InjectionProgressLog.copyDylibSucceeded("WCRefine.dylib"),
            InjectionProgressLog.discoveredDependencies("WCRefine.dylib"),
            InjectionProgressLog.rewrittenDependencies("WCRefine.dylib"),
            InjectionProgressLog.injectStart("WCRefine.dylib"),
            InjectionProgressLog.injectSucceeded("WCRefine.dylib"),
            InjectionProgressLog.removedPlugIns(),
            InjectionProgressLog.removedWatch(),
            InjectionProgressLog.fileSharingEnabled(),
            InjectionProgressLog.clearedCache()
        ])
        XCTAssertFalse(result.log.contains(L("ipaflow.log.substrateStubCopied")))
        XCTAssertFalse(result.log.contains(L("ipaflow.log.substrateStubWarning")))
        XCTAssertFalse(result.log.contains(InjectionProgressLog.removedAppClips()))
        XCTAssertFalse(result.log.contains { $0.contains("删除Assets.car") })
        XCTAssertFalse(result.log.contains(InjectionProgressLog.zipStart()))
    }

    private func writePlist(to app: URL, executable: String = "Demo") throws {
        let plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleName": "Demo",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
    }

    private func assertContainsInOrder(
        _ log: [String],
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var cursor = log.startIndex
        for item in expected {
            guard let found = log[cursor...].firstIndex(of: item) else {
                XCTFail("缺少 \(item)\n日志:\n\(log.joined(separator: "\n"))", file: file, line: line)
                return
            }
            cursor = log.index(after: found)
        }
    }
}

private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class FinalAuditExtractionBlocker: @unchecked Sendable {
    private let lock = NSLock()
    private let existingWorkDirectories: Set<String>
    private var blocked = false

    init() throws {
        existingWorkDirectories = Set(try Self.workDirectories().map(\.path))
    }

    var didBlock: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func blockFinalAuditExtraction() {
        lock.lock()
        defer { lock.unlock() }
        guard !blocked,
              let work = try? Self.workDirectories().first(where: {
                  !existingWorkDirectories.contains($0.path)
              })
        else { return }

        let finalAudit = work.appendingPathComponent("final-audit")
        blocked = FileManager.default.createFile(
            atPath: finalAudit.path,
            contents: Data("second full extraction blocked by test".utf8)
        )
    }

    private static func workDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.lastPathComponent.hasPrefix("injection-plan-") }
    }
}

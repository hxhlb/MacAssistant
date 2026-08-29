import XCTest
@testable import MacAssistantKit

final class BundleMachOWorkflowTests: XCTestCase {
    /// 断言里写死了中文文案,不固定语言的话在英文系统上会失败。
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8((value >> UInt32($0 * 8)) & 0xff) }
    }

    private func thinMachO(cpuSubtype: UInt32 = 0, encrypted: Bool = false) -> Data {
        var bytes = u32(0xFEED_FACF) + u32(0x0100_000C) + u32(cpuSubtype)
        bytes += u32(2) + u32(encrypted ? 1 : 0) + u32(encrypted ? 24 : 0) + u32(0) + u32(0)
        if encrypted {
            bytes += u32(0x2C) + u32(24) + u32(0) + u32(0) + u32(1) + u32(0)
        }
        return Data(bytes)
    }

    private func writeBundle(
        _ bundle: URL,
        executable: String,
        bundleID: String,
        extensionPoint: String? = nil,
        machO: Data? = nil
    ) throws {
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": bundleID,
            "CFBundleName": bundle.deletingPathExtension().lastPathComponent
        ]
        if let extensionPoint {
            plist["NSExtension"] = ["NSExtensionPointIdentifier": extensionPoint]
        }
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        ).write(to: bundle.appendingPathComponent("Info.plist"))
        if let machO {
            try machO.write(to: bundle.appendingPathComponent(executable))
        }
    }

    private func makeFixture(at root: URL) throws -> URL {
        let app = root.appendingPathComponent("Demo.app")
        try writeBundle(
            app,
            executable: "Demo",
            bundleID: "com.example.demo",
            machO: thinMachO()
        )

        let framework = app.appendingPathComponent("Frameworks/Kit.framework")
        try writeBundle(
            framework,
            executable: "Kit",
            bundleID: "com.example.kit",
            machO: thinMachO(cpuSubtype: 2)
        )
        try thinMachO().write(to: app.appendingPathComponent("Frameworks/Loose.dylib"))

        try writeBundle(
            app.appendingPathComponent("PlugIns/Share.appex"),
            executable: "Share",
            bundleID: "com.example.demo.share",
            extensionPoint: "com.apple.share-services",
            machO: thinMachO(encrypted: true)
        )
        try writeBundle(
            app.appendingPathComponent("Watch/WatchDemo.app"),
            executable: "WatchDemo",
            bundleID: "com.example.demo.watch",
            machO: thinMachO()
        )
        try writeBundle(
            app.appendingPathComponent("AppClips/Clip.app"),
            executable: "Clip",
            bundleID: "com.example.demo.clip",
            machO: thinMachO()
        )

        let invalid = app.appendingPathComponent("Frameworks/Broken.framework")
        try writeBundle(
            invalid,
            executable: "Missing",
            bundleID: "com.example.broken",
            machO: nil
        )
        return app
    }

    func testPreferredInjectionHostRanksThreeThenTwoThenLite() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "preferred-host")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("WeChat.app")
        try writeBundle(app, executable: "WeChat", bundleID: "com.tencent.wx", machO: thinMachO())
        try writeBundle(
            app.appendingPathComponent("Frameworks/ProtobufLite.framework"),
            executable: "ProtobufLite",
            bundleID: "com.tencent.protobuf",
            machO: thinMachO()
        )
        XCTAssertEqual(
            PreferredInjectionHost.relativePath(in: app),
            "Frameworks/ProtobufLite.framework/ProtobufLite"
        )

        try writeBundle(
            app.appendingPathComponent("Frameworks/ProtobufLite2.framework"),
            executable: "ProtobufLite2",
            bundleID: "com.tencent.protobuf2",
            machO: thinMachO()
        )
        XCTAssertEqual(
            PreferredInjectionHost.relativePath(in: app),
            "Frameworks/ProtobufLite2.framework/ProtobufLite2"
        )

        try writeBundle(
            app.appendingPathComponent("Frameworks/ProtobufLite3.framework"),
            executable: "ProtobufLite3",
            bundleID: "com.tencent.protobuf3",
            machO: thinMachO()
        )
        XCTAssertEqual(
            PreferredInjectionHost.relativePath(in: app),
            "Frameworks/ProtobufLite3.framework/ProtobufLite3"
        )
        XCTAssertEqual(
            PreferredInjectionHost.relativePath(in: app, preferring: .protobufLite2),
            "Frameworks/ProtobufLite2.framework/ProtobufLite2"
        )

        let session = try InjectionTargetDiscovery.open(.app(app))
        let recommended = session.targets.filter(\.isRecommended)
        XCTAssertEqual(recommended.map(\.relativePath), ["WeChat"])
        XCTAssertTrue(session.targets.first { $0.kind == .mainExecutable }?.isRecommended ?? false)
        XCTAssertFalse(session.targets.contains { $0.relativePath.contains("ProtobufLite") && $0.isRecommended })
    }

    func testPreferredInjectionHostAcceptsBareProtobufLite3File() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "preferred-bare")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("WeChat.app")
        try writeBundle(app, executable: "WeChat", bundleID: "com.tencent.wx", machO: thinMachO())
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Frameworks", isDirectory: true),
            withIntermediateDirectories: true
        )
        try thinMachO().write(to: app.appendingPathComponent("Frameworks/ProtobufLite3"))
        XCTAssertEqual(PreferredInjectionHost.relativePath(in: app), "Frameworks/ProtobufLite3")
    }

    func testTargetDiscoveryFindsStructuredTargetsAndSkipsInvalidExecutable() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "targets-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFixture(at: root)

        let session = try InjectionTargetDiscovery.open(.app(app))
        XCTAssertEqual(session.targets.first?.kind, .mainExecutable)
        XCTAssertEqual(session.targets.first?.relativePath, "Demo")
        XCTAssertTrue(session.targets.contains {
            $0.kind == .framework && $0.relativePath == "Frameworks/Kit.framework/Kit"
                && $0.architectures.contains("arm64e")
        })
        XCTAssertTrue(session.targets.contains {
            $0.kind == .appExtension && $0.bundleID == "com.example.demo.share"
                && $0.extensionPointIdentifier == "com.apple.share-services" && $0.cryptid == 1
        })
        XCTAssertTrue(session.targets.contains { $0.kind == .watchApp && $0.restrictionNote != nil })
        XCTAssertTrue(session.targets.contains { $0.kind == .appClip && $0.restrictionNote != nil })
        XCTAssertFalse(session.targets.contains { $0.relativePath.contains("Broken.framework/Missing") })
        XCTAssertEqual(Set(session.targets.map(\.id)).count, session.targets.count)
    }

    func testComponentSummaryKeepsWatchExtensionsAndClipsDistinct() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "components-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try InjectionTargetDiscovery.open(.app(makeFixture(at: root)))

        XCTAssertEqual(session.components.filter { $0.kind == .watch }.map(\.bundleID), ["com.example.demo.watch"])
        XCTAssertEqual(session.components.filter { $0.kind == .appExtension }.map(\.bundleID), ["com.example.demo.share"])
        XCTAssertEqual(session.components.filter { $0.kind == .appClip }.map(\.bundleID), ["com.example.demo.clip"])
        XCTAssertTrue(session.components.allSatisfy { $0.size >= 0 })
    }

    func testPreflightListsActualComponentRemovalBundles() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "removal-summary-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFixture(at: root)
        let dylib = root.appendingPathComponent("Payload.dylib")
        try thinMachO().write(to: dylib)
        let report = try IpaInjectionWorkflow.preflight(InjectionPlan(
            input: .app(app),
            items: [InjectionItem(dylibURL: dylib)],
            components: InjectionComponentPolicy(
                watch: .preserve,
                plugIns: .remove,
                appClips: .preserve,
                destructiveRemovalConfirmed: true
            ),
            signing: .none
        ))

        XCTAssertEqual(report.componentRemovals.map(\.bundleID), ["com.example.demo.share"])
        XCTAssertTrue(report.componentRemovals.allSatisfy { $0.kind == .appExtension })
    }

    func testIPAInputResolvesMainExecutableBeforeBinaryAnalysis() throws {
        guard ExternalTool.zip.isAvailable, ExternalTool.unzip.isAvailable else {
            throw XCTSkip("缺少 zip/unzip")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "binary-ipa-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveRoot = root.appendingPathComponent("archive")
        _ = try makeFixture(at: archiveRoot.appendingPathComponent("Payload"))
        let ipa = root.appendingPathComponent("Demo.ipa")
        let zipped = try ExternalTool.zip.run(["-qry", ipa.path, "Payload"], currentDirectory: archiveRoot)
        XCTAssertTrue(zipped.succeeded, zipped.combinedOutput)

        let session = try BinaryAnalysisSession.open(ipa)
        let selected = try XCTUnwrap(session.selectedTarget)
        XCTAssertEqual(session.inputKind, .ipa)
        XCTAssertEqual(selected.kind, .mainExecutable)
        XCTAssertNotEqual(selected.fileURL.standardizedFileURL, ipa.standardizedFileURL)
        XCTAssertTrue(MachOIdentifier.isMachO(fileAt: selected.fileURL))
        XCTAssertNoThrow(try session.analysis(targetID: selected.id))
    }

    func testExtractSelectedVerifiesHashAndAllWritesManifest() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "binary-export-fixture")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeFixture(at: root)
        let session = try BinaryAnalysisSession.open(app)
        let selected = try XCTUnwrap(session.selectedTarget)

        let selectedOutput = root.appendingPathComponent("Selected")
        let exported = try session.extractSelected(targetID: selected.id, to: selectedOutput)
        XCTAssertEqual(try DylibService.sha256(fileAt: exported), try DylibService.sha256(fileAt: selected.fileURL))
        XCTAssertThrowsError(try session.extractSelected(targetID: selected.id, to: selectedOutput))

        let all = try session.extractAll(to: root.appendingPathComponent("Exports"), flatten: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: all.manifestURL.path))
        XCTAssertEqual(all.entries.count, session.targets.count)
        XCTAssertTrue(all.entries.contains { $0.relativePath == "Frameworks/Kit.framework/Kit" })
    }

    func testWeakLoadKindAndPermissionGuidanceUsePlainLanguage() {
        XCTAssertEqual(InjectionLoadKind.required.loadCommandName, "LC_LOAD_DYLIB")
        XCTAssertEqual(InjectionLoadKind.weak.loadCommandName, "LC_LOAD_WEAK_DYLIB")
        let path = URL(fileURLWithPath: "/Users/test/Downloads/Demo.ipa")
        let text = FileSystemHelper.userFacingAccessError(
            CocoaError(.fileReadNoPermission),
            paths: [path]
        )
        XCTAssertTrue(text.contains(path.path))
        XCTAssertTrue(text.contains("文件与文件夹"))
        XCTAssertTrue(text.contains("选择的文件"))
        // zip 写只读快照目录失败时文案里也有 Permission denied，那不是 TCC。
        XCTAssertFalse(
            FileSystemHelper.isAccessPermissionError(
                IpaError.commandFailed(
                    "zip I/O error: Permission denied\nzip error: Could not create output file"
                )
            )
        )
        XCTAssertTrue(FileSystemHelper.isAccessPermissionError(CocoaError(.fileReadNoPermission)))
    }
}

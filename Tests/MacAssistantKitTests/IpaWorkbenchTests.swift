import XCTest
@testable import MacAssistantKit

/// 拖入式 IPA 工作台的 Kit 层核心逻辑测试。覆盖:输入分类、签名三态、源快照不可变、
/// recipe 往返、审计脱敏、计划装配,以及签名三态到产物状态的映射(确保不会误标)。
final class IpaWorkbenchTests: XCTestCase {

    // MARK: - 工作项 1:输入分类

    func testInputClassificationByExtension() {
        let cases: [(String, WorkspaceInputRole)] = [
            ("Demo.ipa", .ipa),
            ("Demo.app", .app),
            ("tweak.deb", .deb),
            ("MyTweak.dylib", .dylib),
            ("Foo.framework", .framework),
            ("Bar.bundle", .bundle),
            ("dev.mobileprovision", .provisioningProfile),
            ("dev.provisionprofile", .provisioningProfile),
            ("cert.p12", .developerCertificate),
            ("cert.pfx", .developerCertificate),
        ]
        for (name, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(WorkspaceInputClassifier.role(for: url), expected, "\(name)")
        }
    }

    func testUnrecognizedInputIsNotGuessed() {
        let url = URL(fileURLWithPath: "/tmp/random.bin")
        XCTAssertEqual(WorkspaceInputClassifier.role(for: url), .unrecognized)
        // 大小写无关。
        XCTAssertEqual(WorkspaceInputClassifier.role(for: URL(fileURLWithPath: "/tmp/A.IPA")), .ipa)
    }

    // MARK: - 工作项 4:签名三态(不会误标)

    private let identity = SigningIdentity(id: "SHA1", name: "Apple Development: Tester (TEAMID)")

    func testSigningDecisionUnsignedWhenNoAssets() {
        let decision = WorkspaceSigningPlanner.decide(
            identity: nil,
            profilesByBundleID: [:],
            requiredBundleIDs: ["com.demo.app"]
        )
        XCTAssertEqual(decision, .unsigned)
        // 未签名不能冒充可交接:映射为「已修改/未签名」,且允许执行(产出待签名产物)。
        XCTAssertTrue(decision.canExecute)
        let output = URL(fileURLWithPath: "/tmp/out.ipa")
        XCTAssertEqual(decision.artifactState(outputURL: output), .modifiedUnsigned(outputURL: output))
    }

    func testSigningDecisionWaitsWhenIdentityMissing() {
        let decision = WorkspaceSigningPlanner.decide(
            identity: nil,
            profilesByBundleID: ["com.demo.app": URL(fileURLWithPath: "/tmp/p.mobileprovision")],
            requiredBundleIDs: ["com.demo.app"]
        )
        XCTAssertTrue(decision.isWaiting)
        // 等待材料时**不允许**执行,避免发布误标记结果。
        XCTAssertFalse(decision.canExecute)
    }

    func testSigningDecisionReadyWithP12FileAndPasswordWithoutIdentity() {
        let p12 = URL(fileURLWithPath: "/tmp/team.p12")
        let provision = URL(fileURLWithPath: "/tmp/app.mobileprovision")
        let decision = WorkspaceSigningPlanner.decide(
            identity: nil,
            profilesByBundleID: [:],
            requiredBundleIDs: ["com.demo.app"],
            extraProfiles: [provision],
            certificateURL: p12,
            certificatePassword: "1",
            method: .p12
        )
        guard case let .readyToSign(recipe) = decision else {
            return XCTFail("有 p12 文件、密码和描述文件就应能执行，不必导入钥匙串")
        }
        XCTAssertEqual(recipe.p12URL, p12)
        XCTAssertEqual(recipe.p12Password, "1")
        XCTAssertEqual(recipe.profilesByBundleID["com.demo.app"], provision)
        XCTAssertTrue(decision.canExecute)
    }

    func testSigningDecisionWaitsWhenP12PasswordEmpty() {
        let decision = WorkspaceSigningPlanner.decide(
            identity: nil,
            profilesByBundleID: [:],
            requiredBundleIDs: ["com.demo.app"],
            extraProfiles: [URL(fileURLWithPath: "/tmp/app.mobileprovision")],
            certificateURL: URL(fileURLWithPath: "/tmp/team.p12"),
            certificatePassword: "  ",
            method: .p12
        )
        XCTAssertTrue(decision.isWaiting)
        XCTAssertFalse(decision.canExecute)
    }

    func testSigningDecisionReadyWithOneProfileForWholeIPA() {
        let decision = WorkspaceSigningPlanner.decide(
            identity: identity,
            profilesByBundleID: ["com.demo.app": URL(fileURLWithPath: "/tmp/app.mobileprovision")],
            requiredBundleIDs: ["com.demo.app", "com.demo.app.ext"]
        )
        guard case let .readyToSign(recipe) = decision else {
            return XCTFail("zsign 一份描述文件就应就绪，不等每个 appex")
        }
        XCTAssertEqual(recipe.identityID, "SHA1")
        XCTAssertNotNil(recipe.profilesByBundleID["com.demo.app"])
        XCTAssertTrue(decision.canExecute)
    }

    func testSigningDecisionReadyWhenUnmappedProfileIsDropped() {
        let provision = URL(fileURLWithPath: "/tmp/unmapped.mobileprovision")
        let decision = WorkspaceSigningPlanner.decide(
            identity: identity,
            profilesByBundleID: [:],
            requiredBundleIDs: ["com.demo.app"],
            extraProfiles: [provision]
        )
        guard case let .readyToSign(recipe) = decision else {
            return XCTFail("对不上 bundle 的描述文件仍应交给 zsign")
        }
        XCTAssertEqual(recipe.profilesByBundleID["com.demo.app"], provision)
    }

    func testSigningDecisionReadyWhenComplete() {
        let profiles = [
            "com.demo.app": URL(fileURLWithPath: "/tmp/app.mobileprovision"),
            "com.demo.app.ext": URL(fileURLWithPath: "/tmp/ext.mobileprovision"),
        ]
        let decision = WorkspaceSigningPlanner.decide(
            identity: identity,
            profilesByBundleID: profiles,
            requiredBundleIDs: ["com.demo.app", "com.demo.app.ext"]
        )
        guard case let .readyToSign(recipe) = decision else { return XCTFail("应就绪可签名") }
        XCTAssertEqual(recipe.identityID, "SHA1")
        XCTAssertEqual(Set(recipe.profilesByBundleID.keys), Set(profiles.keys))
        XCTAssertTrue(decision.canExecute)
        let output = URL(fileURLWithPath: "/tmp/out.ipa")
        XCTAssertEqual(decision.artifactState(outputURL: output), .signedForHandoff(outputURL: output))
        // 就绪态映射为真实设备签名模式。
        if case .realDevice = WorkspaceSigningPlanner.signingMode(for: decision) {} else {
            XCTFail("就绪态应映射为 realDevice 签名")
        }
    }

    func testWaitingDecisionFallsBackToNonSigningMode() {
        // 未就绪的两态若被误用于执行,签名模式必须退化为不真正签名,绝不冒充设备签名。
        let waiting = WorkspaceSigningDecision.waitingForAssets(missingIdentity: true, missingProfileBundleIDs: [])
        if case .realDevice = WorkspaceSigningPlanner.signingMode(for: waiting) {
            XCTFail("等待态不得映射为 realDevice")
        }
        if case .appleID = WorkspaceSigningPlanner.signingMode(for: waiting) {
            XCTFail("等待态不得映射为 appleID")
        }
    }

    func testSigningDecisionReadyWithAppleIDIsFourthState() {
        let recipe = AppleIDSigningRecipe(
            appleID: "a@b.com",
            teamID: "TEAM",
            teamName: "Personal",
            deviceUDID: "00008030-001A2B3C4D5E6F70",
            deviceName: "iPhone"
        )
        let decision = WorkspaceSigningPlanner.decide(
            identity: nil,
            profilesByBundleID: [:],
            requiredBundleIDs: ["com.demo.app"],
            appleID: recipe
        )
        guard case let .readyToSignWithAppleID(ready) = decision else {
            return XCTFail("已登录且已选设备时应进入 Apple ID 就绪态")
        }
        XCTAssertEqual(ready.teamID, "TEAM")
        XCTAssertTrue(decision.isReadyToSign)
        XCTAssertTrue(decision.canExecute)
        if case .appleID = WorkspaceSigningPlanner.signingMode(for: decision) {} else {
            XCTFail("Apple ID 就绪态应映射为 appleID 签名")
        }
        let output = URL(fileURLWithPath: "/tmp/out.ipa")
        XCTAssertEqual(decision.artifactState(outputURL: output), .signedForHandoff(outputURL: output))
    }

    func testSigningDecisionWaitsWhenAppleIDMissingDevice() {
        let recipe = AppleIDSigningRecipe(appleID: "a@b.com", teamID: "TEAM")
        let decision = WorkspaceSigningPlanner.decide(
            identity: nil,
            profilesByBundleID: [:],
            requiredBundleIDs: ["com.demo.app"],
            appleID: recipe
        )
        XCTAssertTrue(decision.isWaiting)
        XCTAssertFalse(decision.canExecute)
    }

    func testCompleteP12TakesPriorityOverAppleID() {
        let profiles = ["com.demo.app": URL(fileURLWithPath: "/tmp/app.mobileprovision")]
        let appleID = AppleIDSigningRecipe(
            appleID: "a@b.com",
            teamID: "TEAM",
            deviceUDID: "00008030-001A2B3C4D5E6F70"
        )
        let decision = WorkspaceSigningPlanner.decide(
            identity: identity,
            profilesByBundleID: profiles,
            requiredBundleIDs: ["com.demo.app"],
            appleID: appleID
        )
        guard case .readyToSign = decision else {
            return XCTFail("完整 p12 材料应优先于 Apple ID")
        }
    }

    func testExplicitNoneIgnoresReadySideloadMaterials() {
        let profiles = ["com.demo.app": URL(fileURLWithPath: "/tmp/app.mobileprovision")]
        let appleID = AppleIDSigningRecipe(
            appleID: "a@b.com",
            teamID: "TEAM",
            deviceUDID: "00008030-001A2B3C4D5E6F70"
        )
        let decision = WorkspaceSigningPlanner.decide(
            identity: identity,
            profilesByBundleID: profiles,
            requiredBundleIDs: ["com.demo.app"],
            appleID: appleID,
            method: SideloadSigningChoice.none
        )
        XCTAssertEqual(decision, .unsigned)
        XCTAssertTrue(decision.canExecute)
    }

    func testExplicitAppleIDIgnoresCompleteP12() {
        let profiles = ["com.demo.app": URL(fileURLWithPath: "/tmp/app.mobileprovision")]
        let appleID = AppleIDSigningRecipe(
            appleID: "a@b.com",
            teamID: "TEAM",
            deviceUDID: "00008030-001A2B3C4D5E6F70"
        )
        let decision = WorkspaceSigningPlanner.decide(
            identity: identity,
            profilesByBundleID: profiles,
            requiredBundleIDs: ["com.demo.app"],
            appleID: appleID,
            method: .appleID
        )
        guard case .readyToSignWithAppleID = decision else {
            return XCTFail("选了 Apple ID 侧载就不应改走 p12")
        }
    }

    func testExplicitP12IgnoresCompleteAppleID() {
        let profiles = ["com.demo.app": URL(fileURLWithPath: "/tmp/app.mobileprovision")]
        let appleID = AppleIDSigningRecipe(
            appleID: "a@b.com",
            teamID: "TEAM",
            deviceUDID: "00008030-001A2B3C4D5E6F70"
        )
        let decision = WorkspaceSigningPlanner.decide(
            identity: identity,
            profilesByBundleID: profiles,
            requiredBundleIDs: ["com.demo.app"],
            appleID: appleID,
            method: .p12
        )
        guard case .readyToSign = decision else {
            return XCTFail("选了 P12 侧载就不应改走 Apple ID")
        }
    }

    func testExplicitP12WaitsWhenMaterialsMissing() {
        let decision = WorkspaceSigningPlanner.decide(
            identity: nil,
            profilesByBundleID: [:],
            requiredBundleIDs: ["com.demo.app"],
            method: .p12
        )
        XCTAssertTrue(decision.isWaiting)
        XCTAssertFalse(decision.canExecute)
    }

    func testProfileAppIDMatching() {
        XCTAssertTrue(IpaWorkbenchControllerMatch("TEAM.com.demo.app", "com.demo.app"))
        XCTAssertTrue(IpaWorkbenchControllerMatch("TEAM.com.demo.*", "com.demo.app"))
        XCTAssertTrue(IpaWorkbenchControllerMatch("TEAM.*", "anything.at.all"))
        XCTAssertFalse(IpaWorkbenchControllerMatch("TEAM.com.other", "com.demo.app"))
    }

    private func IpaWorkbenchControllerMatch(_ appID: String, _ bundleID: String) -> Bool {
        IpaWorkbenchController.appID(appID, matches: bundleID)
    }

    // MARK: - 工作项 6:源快照不可变

    func testSourceSnapshotIsImmutableAndPreservesOriginal() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "snap-test")
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("Payload.ipa")
        let originalBytes = Data("original-bytes".utf8)
        try originalBytes.write(to: original)

        let snapshot = try ImmutableSourceSnapshot.make(of: original)

        // 快照内容与原始一致。
        XCTAssertEqual(try Data(contentsOf: snapshot.snapshotURL), originalBytes)
        // 硬要求:快照在文件系统层面**无法**被原地改写。
        XCTAssertThrowsError(try Data("tampered".utf8).write(to: snapshot.snapshotURL)) { _ in }
        // 根目录 0o555：在快照旁边新建 `.injected.ipa` 也必须失败。执行器若把产物写到这里，
        // zip 会报 Permission denied，并被误展示成「完全磁盘访问」。
        let injectedBesideSnapshot = snapshot.snapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent("Payload.injected.ipa")
        XCTAssertThrowsError(try Data("injected".utf8).write(to: injectedBesideSnapshot)) { _ in }
        // 原始输入未被触碰。
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        // 记录了原始 hash。
        XCTAssertEqual(snapshot.sha256, try DylibService.sha256(fileAt: original))
        XCTAssertFalse(snapshot.sha256.isEmpty)
    }

    @MainActor
    func testProposedOutputURLSitsBesideOriginalNotSnapshot() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "snap-out")
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("WeChat_8075_管替.ipa")
        try Data("ipa".utf8).write(to: original)

        let controller = IpaWorkbenchController()
        controller.adoptSnapshot(try ImmutableSourceSnapshot.make(of: original))

        let output = try XCTUnwrap(controller.proposedOutputURL)
        XCTAssertEqual(output.lastPathComponent, "WeChat_8075_管替.injected.ipa")
        XCTAssertEqual(output.deletingLastPathComponent(), dir)
        XCTAssertNotEqual(
            output.deletingLastPathComponent(),
            controller.snapshot?.snapshotURL.deletingLastPathComponent()
        )
    }

    func testExecuteFromReadOnlySnapshotWritesOutsideSnapshotDirectory() throws {
        for tool in [ExternalTool.clang, .zip, .unzip, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "snap-exec")
        defer { try? FileManager.default.removeItem(at: root) }

        let ipaRoot = root.appendingPathComponent("ipaRoot")
        let app = ipaRoot.appendingPathComponent("Payload/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleExecutable": "Demo",
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleName": "Demo",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))

        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let main = app.appendingPathComponent("Demo")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", main.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        let plugin = root.appendingPathComponent("Hook.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)

        let original = root.appendingPathComponent("WeChat_8075_管替.ipa")
        XCTAssertTrue(try ExternalTool.zip.run(
            ["-qry", original.path, "Payload"],
            currentDirectory: ipaRoot
        ).succeeded)

        let snapshot = try ImmutableSourceSnapshot.make(of: original)
        let result = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: snapshot.injectionInput,
                items: [InjectionItem(dylibURL: plugin)],
                signing: .none
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertFalse(
            result.outputURL.path.hasPrefix(snapshot.snapshotURL.deletingLastPathComponent().path + "/")
        )
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: snapshot.snapshotURL))
    }

    func testSourceSnapshotInjectionInputMatchesExtension() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "snap-input")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ipa = dir.appendingPathComponent("A.ipa")
        try Data("x".utf8).write(to: ipa)
        let snap = try ImmutableSourceSnapshot.make(of: ipa)
        if case .ipa = snap.injectionInput {} else { XCTFail("应为 ipa 输入") }
    }

    // MARK: - 工作项 6:审计脱敏

    func testAuditRedactsHomePaths() throws {
        let home = "/Users/tester"
        let report = WorkspaceAuditReport(
            toolVersion: "1.0.0-beta.1",
            inputName: "/Users/tester/Demo.ipa",
            inputSHA256: "hash",
            outputName: "/Users/tester/out/Demo.ipa",
            pluginHashes: ["/Users/tester/t.dylib": "h"],
            finalInjectedDylibPosition: "/Users/tester/App.app <- @rpath/t.dylib",
            changedPaths: ["/Users/tester/App.app/Frameworks/t.dylib"],
            signingOutcome: "modified-unsigned"
        )
        let redacted = report.redactingHomePaths(homePath: home)
        XCTAssertEqual(redacted.inputName, "~/Demo.ipa")
        XCTAssertEqual(redacted.outputName, "~/out/Demo.ipa")
        XCTAssertTrue(redacted.finalInjectedDylibPosition?.hasPrefix("~/App.app") ?? false)
        XCTAssertEqual(redacted.changedPaths, ["~/App.app/Frameworks/t.dylib"])
        XCTAssertEqual(redacted.pluginHashes.keys.first, "~/t.dylib")
        // 兜底:即便 home 不同,别的用户名前缀也脱敏。
        let other = WorkspacePathRedactor.redact("/Users/someoneelse/x", homePath: home)
        XCTAssertEqual(other, "~/x")
    }

    func testAuditJSONIsRedactedByDefault() throws {
        let report = WorkspaceAuditReport(
            toolVersion: "v",
            inputName: "/Users/tester/Demo.ipa",
            inputSHA256: "hash",
            signingOutcome: "modified-unsigned"
        )
        let json = try report.jsonData()
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("/Users/tester"))
        XCTAssertTrue(text.contains("~/Demo.ipa"))
    }

    // MARK: - 工作项 3:recipe 往返 + 最后 dylib 位置

    func testRecipeRoundTrips() throws {
        var recipe = InjectionRecipe(name: "My Preset")
        recipe.injectionOrder = ["a.dylib", "b.dylib"]
        recipe.targetMappings = [
            RecipeTargetMapping(dylibName: "a.dylib"),
            RecipeTargetMapping(
                dylibName: "b.dylib",
                targetRelativePath: "PlugIns/Ext.appex/Ext",
                injectionHost: .preferredFramework,
                loadKind: .weak,
                existingPolicy: .skip
            ),
        ]
        recipe.leaveUnsigned = true
        recipe.metadata.bundleID = "com.example.rewritten"
        recipe.components.watch = .remove
        let data = try recipe.encoded()
        let decoded = try InjectionRecipe.decode(data)
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.finalDylibName, "b.dylib")
        XCTAssertEqual(decoded.mapping(for: "b.dylib")?.targetRelativePath, "PlugIns/Ext.appex/Ext")
        XCTAssertEqual(decoded.mapping(for: "b.dylib")?.injectionHost, .preferredFramework)
        XCTAssertEqual(decoded.mapping(for: "a.dylib")?.injectionHost, .automatic)
        XCTAssertTrue(decoded.leaveUnsigned)
        XCTAssertEqual(decoded.sideloadSigning, .none)
        XCTAssertEqual(decoded.metadata.bundleID, "com.example.rewritten")
        XCTAssertEqual(decoded.components.watch, .remove)
    }

    func testRecipeSaveLoad() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "recipe")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("preset.json")
        let recipe = InjectionRecipe(name: "Saved", injectionOrder: ["x.dylib"])
        try recipe.save(to: url)
        XCTAssertEqual(try InjectionRecipe.load(from: url), recipe)
    }

    /// schema 不认识时必须明确报错,不猜、不静默按当前版本解析;缺字段的旧文件按当前版本兼容。
    func testRecipeRejectsUnsupportedSchemaVersion() throws {
        let unsupported = Data(#"{"schemaVersion":999,"name":"x"}"#.utf8)
        XCTAssertThrowsError(try InjectionRecipe.decode(unsupported)) { error in
            guard case let InjectionRecipeError.unsupportedSchemaVersion(found, _) = error else {
                return XCTFail("应为 unsupportedSchemaVersion,得到 \(error)")
            }
            XCTAssertEqual(found, 999)
        }
        let current = Data(#"{"schemaVersion":1,"name":"x"}"#.utf8)
        XCTAssertEqual(try InjectionRecipe.decode(current).name, "x")
        let missing = Data(#"{"name":"x"}"#.utf8)
        XCTAssertEqual(
            try InjectionRecipe.decode(missing).schemaVersion,
            InjectionRecipe.currentSchemaVersion
        )
        // 缺字段的旧预设保持原先会签名的行为；新工作台 init 才默认勾选仅修改。
        XCTAssertFalse(try InjectionRecipe.decode(missing).leaveUnsigned)
        // 旧预设里的 macOS 文件访问字段直接忽略，不再影响执行。
        let legacyAccess = Data(#"{"name":"x","fileAccessBehavior":"require"}"#.utf8)
        XCTAssertEqual(try InjectionRecipe.decode(legacyAccess).name, "x")
    }

    // MARK: - 工作项 1(诚实报告):未确认依赖写进审计,脱敏后仍保留

    func testAuditReportKeepsUnconfirmedDependencies() throws {
        let dep = IpaUnconfirmedDependency(
            referencedBy: "Payload/A.app/A",
            installPath: "@rpath/libX.dylib",
            fileName: "libX.dylib",
            classification: .deviceProvided,
            evidence: "not resolvable locally"
        )
        let report = WorkspaceAuditReport(
            toolVersion: "v",
            inputName: "/Users/tester/A.ipa",
            inputSHA256: "h",
            unconfirmedDependencies: [dep],
            signingOutcome: "modified-unsigned"
        )
        // 脱敏副本不得丢掉未确认依赖,也不得把它当成已解析。
        XCTAssertEqual(
            report.redactingHomePaths(homePath: "/Users/tester").unconfirmedDependencies,
            [dep]
        )
        let text = String(decoding: try report.jsonData(), as: UTF8.self)
        XCTAssertTrue(text.contains("libX.dylib"))
    }

    // MARK: - 计划装配

    func testPlanAssemblyMapsMainToExecutableAndRespectsRecipe() throws {
        let main = URL(fileURLWithPath: "/tmp/Main.dylib")
        let helper = URL(fileURLWithPath: "/tmp/Helper.dylib")
        var recipe = InjectionRecipe(name: "p")
        recipe.targetMappings = [
            RecipeTargetMapping(
                dylibName: "Helper.dylib",
                targetRelativePath: "PlugIns/Ext.appex/Ext",
                loadKind: .weak
            )
        ]
        let plan = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: [main, helper],
            frameworks: [URL(fileURLWithPath: "/tmp/Dep.framework")],
            recipe: recipe,
            signing: .adHoc
        ))
        XCTAssertEqual(plan.items.count, 2)
        // 主插件无映射、未点名宿主 → 只打主程序，不自动改 Frameworks。
        XCTAssertEqual(plan.items[0].target, .mainExecutable)
        // helper 有相对路径映射 → 落到指定 Mach-O。
        if case let .relativeMachO(path) = plan.items[1].target {
            XCTAssertEqual(path.rawValue, "PlugIns/Ext.appex/Ext")
        } else {
            XCTFail("helper 应映射到相对 Mach-O")
        }
        XCTAssertEqual(plan.items[1].loadKind, .weak)
        // Framework 资源落到 IPA 的 Frameworks 目录。
        XCTAssertEqual(plan.resources.count, 1)
        XCTAssertEqual(plan.resources[0].destination.rawValue, "Frameworks/Dep.framework")
    }

    func testPlanAssemblyAutomaticHostKeepsEveryDylibOnMainExecutable() throws {
        let recipe = InjectionRecipe(name: "p")
        XCTAssertEqual(recipe.injectionHost, .automatic)
        let plan = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: [
                URL(fileURLWithPath: "/tmp/MMlibAntiDetect.dylib"),
                URL(fileURLWithPath: "/tmp/WCRefine.dylib")
            ],
            recipe: recipe,
            signing: .none
        ))
        XCTAssertEqual(plan.items.map(\.target), [.mainExecutable, .mainExecutable])
    }

    func testPlanAssemblyPinsNamedProtobufLiteHostOnlyOnThatDylib() throws {
        var recipe = InjectionRecipe(name: "p")
        recipe.injectionHost = .protobufLite2
        recipe.targetMappings = [
            RecipeTargetMapping(
                dylibName: "Hook.dylib",
                injectionHost: .protobufLite2
            )
        ]
        let plan = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: [
                URL(fileURLWithPath: "/tmp/MMlibAntiDetect.dylib"),
                URL(fileURLWithPath: "/tmp/Hook.dylib")
            ],
            recipe: recipe,
            signing: .adHoc
        ))
        XCTAssertEqual(plan.items[0].target, .mainExecutable)
        XCTAssertEqual(plan.items[1].target, .namedFrameworkHost("ProtobufLite2"))
    }

    func testPlanAssemblyIgnoresGlobalInjectionHost() throws {
        var recipe = InjectionRecipe(name: "p")
        recipe.injectionHost = .protobufLite
        let plan = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: [
                URL(fileURLWithPath: "/tmp/MMlibAntiDetect.dylib"),
                URL(fileURLWithPath: "/tmp/WCRefine.dylib")
            ],
            recipe: recipe,
            signing: .none
        ))
        XCTAssertEqual(plan.items.map(\.target), [.mainExecutable, .mainExecutable])
    }

    func testPlanAssemblyPreferredFrameworkIsPerDylibOption() throws {
        var recipe = InjectionRecipe(name: "p")
        recipe.targetMappings = [
            RecipeTargetMapping(
                dylibName: "OptionalHost.dylib",
                injectionHost: .preferredFramework
            )
        ]
        let plan = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: [
                URL(fileURLWithPath: "/tmp/MMlibAntiDetect.dylib"),
                URL(fileURLWithPath: "/tmp/OptionalHost.dylib")
            ],
            recipe: recipe,
            signing: .none
        ))
        XCTAssertEqual(plan.items[0].target, .mainExecutable)
        XCTAssertEqual(plan.items[1].target, .preferredFrameworkHost)
    }

    @MainActor
    func testSetPluginInjectionHostWritesOnlyThatMapping() throws {
        let controller = IpaWorkbenchController()
        controller.ingestSimpleInputs([
            URL(fileURLWithPath: "/tmp/MMlibAntiDetect.dylib"),
            URL(fileURLWithPath: "/tmp/WCRefine.dylib")
        ])
        XCTAssertEqual(controller.plugins.count, 2)
        controller.setPluginInjectionHost(controller.plugins[0].id, .preferredFramework)
        XCTAssertEqual(controller.injectionHost(for: controller.plugins[0]), .preferredFramework)
        XCTAssertEqual(controller.injectionHost(for: controller.plugins[1]), .automatic)
        let plan = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: controller.plugins.map(\.dylibURL),
            recipe: controller.recipe,
            signing: .none
        ))
        XCTAssertEqual(plan.items[0].target, .preferredFrameworkHost)
        XCTAssertEqual(plan.items[1].target, .mainExecutable)
    }

    func testLegacyRecipeJSONDefaultsInjectionHostToAutomatic() throws {
        let data = Data(#"{"schemaVersion":1,"name":"x"}"#.utf8)
        let recipe = try InjectionRecipe.decode(data)
        XCTAssertEqual(recipe.injectionHost, .automatic)
        let mappingJSON = Data(#"{"dylibName":"Foo.dylib"}"#.utf8)
        let mapping = try JSONDecoder().decode(RecipeTargetMapping.self, from: mappingJSON)
        XCTAssertEqual(mapping.injectionHost, .automatic)
        XCTAssertEqual(try mapping.resolvedTarget(), .mainExecutable)
    }

    func testFinalDylibPositionFromResult() {
        let entry = IpaArtifactAuditEntry(
            itemID: UUID(),
            targetRelativePath: "App.app/App",
            loadPath: "@rpath/Main.dylib",
            auditedSliceCount: 1,
            loadKind: .required
        )
        let audit = IpaArtifactAuditReport(
            payloadStructureValid: true,
            entries: [entry],
            unresolvedDependencies: [],
            signatureVerified: nil
        )
        let preflight = IpaPreflightReport(
            inputAppName: "App", bundleID: "com.demo", targets: [], componentRemovals: [], findings: []
        )
        let diff = IpaArtifactDiffReport(before: [], after: [], diffs: [])
        let result = IpaInjectionExecutionResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.ipa"),
            preflight: preflight, audit: audit, diff: diff, log: []
        )
        XCTAssertEqual(
            WorkspacePlanAssembler.finalDylibPosition(from: result),
            "App.app/App ← @rpath/Main.dylib"
        )
    }

    // MARK: - 工作项 2:执行前独立预检 + blocker 拦执行

    @MainActor
    func testPreflightBlockersDisableExecution() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "wb-preflight")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ipa = dir.appendingPathComponent("A.ipa")
        try Data("x".utf8).write(to: ipa)

        let controller = IpaWorkbenchController()
        controller.adoptSnapshot(try ImmutableSourceSnapshot.make(of: ipa))
        controller.ingestSimpleInputs([URL(fileURLWithPath: "/tmp/Main.dylib")])
        XCTAssertEqual(controller.enabledPlugins.count, 1)
        // 未跑预检、无其它阻断 → 可执行(预检是可选的前置检查,不跑不因此拦)。
        XCTAssertTrue(controller.canExecute)

        controller.setPluginEnabled(controller.plugins[0].id, false)
        XCTAssertTrue(controller.enabledPlugins.isEmpty)
        XCTAssertFalse(controller.canExecute)
        controller.setPluginEnabled(controller.plugins[0].id, true)
        XCTAssertTrue(controller.canExecute)

        let blocker = IpaPreflightFinding(severity: .blocker, code: "x.blocker", message: "boom")
        let warning = IpaPreflightFinding(severity: .warning, code: "x.warn", message: "careful")
        controller.applyPreflight(IpaPreflightReport(
            inputAppName: "A", bundleID: "com.demo", targets: [], componentRemovals: [],
            findings: [blocker, warning]
        ))
        XCTAssertEqual(controller.phase, .preflighted)
        XCTAssertTrue(controller.preflightHasBlockers)
        // 有 blocker 时执行按钮不可用。
        XCTAssertFalse(controller.canExecute)
        // 汇总清单把预检 findings 一并纳入,供用户在一处看全。
        XCTAssertTrue(controller.combinedPreflightFindings.contains { $0.code == "x.blocker" })
        XCTAssertTrue(controller.combinedPreflightFindings.contains { $0.code == "x.warn" })

        controller.applyPreflight(IpaPreflightReport(
            inputAppName: "A", bundleID: "com.demo", targets: [], componentRemovals: [],
            findings: [warning]
        ))
        XCTAssertFalse(controller.preflightHasBlockers)
        XCTAssertTrue(controller.canExecute)
    }

    @MainActor
    func testRecordExecutionCarriesUnconfirmedDependenciesAndResult() {
        let controller = IpaWorkbenchController()
        let dep = IpaUnconfirmedDependency(
            referencedBy: "Payload/A.app/A",
            installPath: "@rpath/libX.dylib",
            fileName: "libX.dylib",
            classification: .deviceProvided,
            evidence: "e"
        )
        let audit = IpaArtifactAuditReport(
            payloadStructureValid: true,
            entries: [],
            unresolvedDependencies: [],
            unconfirmedDependencies: [dep],
            signatureVerified: nil
        )
        let preflight = IpaPreflightReport(
            inputAppName: "A", bundleID: "com.demo", targets: [], componentRemovals: [], findings: []
        )
        let diff = IpaArtifactDiffReport(before: [], after: [], diffs: [])
        let result = IpaInjectionExecutionResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.ipa"),
            preflight: preflight, audit: audit, diff: diff, log: []
        )
        controller.recordExecution(result, toolVersion: "v")
        XCTAssertEqual(controller.audit?.unconfirmedDependencies, [dep])
        XCTAssertNotNil(controller.executionResult, "结果原件需保留,供 UI 展示未确认依赖与 diff")
    }

    func testSourceMetadataFillsFromPlistAndDetectsWeChat() {
        XCTAssertTrue(AppBundleMetadataSummary.isWeChat(bundleID: "com.tencent.xin"))
        XCTAssertTrue(AppBundleMetadataSummary.isWeChat(bundleID: "com.tencent.xin.iosrxwy"))
        XCTAssertTrue(AppBundleMetadataSummary.isWeChat(bundleID: "com.example.x", executable: "WeChat"))
        XCTAssertFalse(AppBundleMetadataSummary.isWeChat(bundleID: "com.tencent.mqq"))

        let summary = AppBundleMetadataSummary.from(
            plist: [
                "CFBundleDisplayName": "微信",
                "CFBundleIdentifier": "com.tencent.xin",
                "CFBundleShortVersionString": "8.0.60",
                "MinimumOSVersion": "15.0",
                "CFBundleExecutable": "WeChat",
            ],
            fallbackName: "WeChat.app"
        )
        XCTAssertEqual(summary.displayName, "微信")
        XCTAssertEqual(summary.bundleID, "com.tencent.xin")
        XCTAssertEqual(summary.shortVersion, "8.0.60")
        XCTAssertEqual(summary.minimumOSVersion, "15.0")
        XCTAssertTrue(summary.isWeChat)
    }

    @MainActor
    func testNewWorkbenchEnablesFileSharingByDefault() {
        XCTAssertTrue(IpaWorkbenchController().recipe.metadata.enableFileSharing)
        let controller = IpaWorkbenchController()
        controller.recipe.metadata.enableFileSharing = false
        XCTAssertFalse(controller.recipe.metadata.enableFileSharing)
    }

    @MainActor
    func testNewWorkbenchLeavesUnsignedByDefault() {
        let controller = IpaWorkbenchController()
        XCTAssertTrue(controller.recipe.leaveUnsigned)
        XCTAssertEqual(controller.recipe.sideloadSigning, .none)
        XCTAssertEqual(controller.signingDecision, .unsigned)
        if case .none = controller.resolvedSigningMode {} else {
            XCTFail("默认仅修改配置时应跳过签名")
        }
        controller.recipe.leaveUnsigned = false
        XCTAssertFalse(controller.recipe.leaveUnsigned)
        XCTAssertEqual(controller.recipe.sideloadSigning, .appleID)
    }

    @MainActor
    func testAdoptSnapshotClearsIdentityOverridesAndAppliesSourceMetadata() throws {
        let controller = IpaWorkbenchController()
        controller.recipe.metadata.displayName = "旧名字"
        controller.recipe.metadata.bundleID = "com.old"
        controller.recipe.metadata.enableFileSharing = true
        controller.applySourceMetadata(
            AppBundleMetadataSummary(displayName: "微信", bundleID: "com.tencent.xin", isWeChat: true)
        )
        XCTAssertTrue(controller.isWeChatTarget)

        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "wb-meta")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ipa = dir.appendingPathComponent("A.ipa")
        try Data("x".utf8).write(to: ipa)
        controller.adoptSnapshot(try ImmutableSourceSnapshot.make(of: ipa))
        XCTAssertNil(controller.recipe.metadata.displayName)
        XCTAssertNil(controller.recipe.metadata.bundleID)
        XCTAssertTrue(controller.recipe.metadata.enableFileSharing)
        XCTAssertNil(controller.sourceAppMetadata)
        XCTAssertFalse(controller.isWeChatTarget)
    }

    func testPlanAssemblyAppliesDefaultMinimumOS() throws {
        var recipe = InjectionRecipe(name: "p")
        recipe.metadata.bundleID = "com.demo.multi"
        let defaulted = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: [URL(fileURLWithPath: "/tmp/Main.dylib")],
            recipe: recipe,
            signing: .none
        ))
        XCTAssertEqual(defaulted.metadata.minimumOSVersion, InjectionMetadataChanges.defaultMinimumOSVersion)
        XCTAssertEqual(defaulted.metadata.bundleID, "com.demo.multi")

        recipe.metadata.minimumOSVersion = "16.0"
        let pinned = try WorkspacePlanAssembler.makePlan(.init(
            input: .ipa(URL(fileURLWithPath: "/tmp/A.ipa")),
            orderedDylibs: [URL(fileURLWithPath: "/tmp/Main.dylib")],
            recipe: recipe,
            signing: .none
        ))
        XCTAssertEqual(pinned.metadata.minimumOSVersion, "16.0")
    }

    @MainActor
    func testLeaveUnsignedForcesUnsignedEvenWithSigningMaterials() {
        let controller = IpaWorkbenchController()
        controller.applyTargetContext(identity: nil, requiredBundleIDs: ["com.demo.app"])
        controller.selectedIdentity = identity
        controller.appleIDRecipe = AppleIDSigningRecipe(
            appleID: "a@b.com",
            teamID: "TEAM",
            deviceUDID: "00008030-001A2B3C4D5E6F70"
        )
        controller.recipe.leaveUnsigned = true
        XCTAssertEqual(controller.signingDecision, .unsigned)
        if case .none = controller.resolvedSigningMode {} else {
            XCTFail("仅修改配置时必须强制不签名")
        }

        controller.recipe.leaveUnsigned = false
        guard case .readyToSignWithAppleID = controller.signingDecision else {
            return XCTFail("取消仅修改后应回到 Apple ID 就绪态")
        }
        if case .appleID = controller.resolvedSigningMode {} else {
            XCTFail("取消仅修改且 Apple ID 齐备时应走 appleID")
        }
    }

    @MainActor
    func testIngestP12IsCertificateNotUnrecognized() {
        let controller = IpaWorkbenchController()
        let p12 = URL(fileURLWithPath: "/tmp/team.p12")
        _ = controller.ingestSimpleInputs([p12])
        XCTAssertEqual(controller.pendingCertificateURL, p12)
        XCTAssertTrue(controller.unrecognized.isEmpty)
        XCTAssertEqual(controller.recipe.sideloadSigning, SideloadSigningChoice.none)
        XCTAssertFalse(controller.hasCertificateSideloadPair)
    }

    @MainActor
    func testIngestP12AndProfileSelectsCertificateSideload() {
        let controller = IpaWorkbenchController()
        XCTAssertEqual(controller.recipe.sideloadSigning, SideloadSigningChoice.none)
        _ = controller.ingestSimpleInputs([
            URL(fileURLWithPath: "/tmp/team.p12"),
            URL(fileURLWithPath: "/tmp/app.mobileprovision"),
        ])
        XCTAssertEqual(controller.pendingCertificateURL?.lastPathComponent, "team.p12")
        XCTAssertEqual(controller.provisioningProfiles.count, 1)
        XCTAssertTrue(controller.hasCertificateSideloadPair)
        XCTAssertEqual(controller.recipe.sideloadSigning, .p12)
        XCTAssertEqual(controller.developerCertificatePassword, "1")
        controller.applyTargetContext(identity: nil, requiredBundleIDs: ["com.demo.app"])
        XCTAssertTrue(controller.signingDecision.canExecute)
        guard case let .readyToSign(recipe) = controller.signingDecision else {
            return XCTFail("凑齐 p12、密码和描述文件后应可执行")
        }
        XCTAssertEqual(recipe.p12Password, "1")
    }

    @MainActor
    func testIngestProfileThenP12SelectsCertificateSideload() {
        let controller = IpaWorkbenchController()
        _ = controller.ingestSimpleInputs([URL(fileURLWithPath: "/tmp/app.mobileprovision")])
        XCTAssertEqual(controller.recipe.sideloadSigning, SideloadSigningChoice.none)
        XCTAssertFalse(controller.hasCertificateSideloadPair)
        _ = controller.ingestSimpleInputs([URL(fileURLWithPath: "/tmp/team.p12")])
        XCTAssertTrue(controller.hasCertificateSideloadPair)
        XCTAssertEqual(controller.recipe.sideloadSigning, .p12)
    }

    func testDefaultDeveloperCertificatePasswordIsOne() {
        XCTAssertEqual(SigningService.defaultDeveloperCertificatePassword, "1")
        XCTAssertEqual(SigningService.resolvedDeveloperCertificatePassword(nil), "1")
        XCTAssertEqual(SigningService.resolvedDeveloperCertificatePassword("  "), "1")
        XCTAssertEqual(SigningService.resolvedDeveloperCertificatePassword("secret"), "secret")
    }
}

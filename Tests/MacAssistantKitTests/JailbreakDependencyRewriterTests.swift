import XCTest
@testable import MacAssistantKit

final class JailbreakDependencyRewriterTests: XCTestCase {

    private let app = URL(fileURLWithPath: "/App.app")
    private var main: URL { app.appendingPathComponent("App") }
    private var plugin: URL {
        app.appendingPathComponent("Frameworks/Tweak.dylib")
    }

    func testRecognizesSubstrateVariantsAndIgnoresPluginPaths() {
        XCTAssertTrue(JailbreakDependencyRewriter.isCydiaSubstrate("/usr/lib/libsubstrate.dylib"))
        XCTAssertTrue(JailbreakDependencyRewriter.isCydiaSubstrate("@rpath/libsubstrate.dylib"))
        XCTAssertTrue(JailbreakDependencyRewriter.isCydiaSubstrate("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"))
        XCTAssertTrue(JailbreakDependencyRewriter.isCydiaSubstrate("libsubstrate.0.dylib"))
        XCTAssertFalse(JailbreakDependencyRewriter.isCydiaSubstrate("/Library/MobileSubstrate/DynamicLibraries/ThemeBox.dylib"))
        XCTAssertFalse(JailbreakDependencyRewriter.isCydiaSubstrate("/usr/lib/libSystem.B.dylib"))
    }

    func testStubPathsDependOnBinaryLocation() {
        XCTAssertEqual(
            JailbreakDependencyRewriter.stubLoadPath(for: main, app: app, mainExecutable: main),
            "@rpath/libsubstrate.dylib"
        )
        XCTAssertEqual(
            JailbreakDependencyRewriter.stubLoadPath(for: plugin, app: app, mainExecutable: main),
            "@loader_path/libsubstrate.dylib"
        )
        XCTAssertEqual(
            JailbreakDependencyRewriter.stubLoadPath(
                for: app.appendingPathComponent("Frameworks/Foo.framework/Foo"),
                app: app,
                mainExecutable: main
            ),
            "@loader_path/../libsubstrate.dylib"
        )
    }

    func testNativeModeUnifiesAllSubstrateVariants() {
        let changes = JailbreakDependencyRewriter.planRewrites(
            for: [
                "/usr/lib/libsubstrate.dylib",
                "@rpath/libsubstrate.dylib",
                "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
            ],
            binary: plugin,
            app: app,
            mainExecutable: main,
            mode: .nativeFramework
        )
        XCTAssertEqual(Set(changes.map(\.to)), ["@rpath/CydiaSubstrate.framework/CydiaSubstrate"])
        XCTAssertFalse(changes.contains { $0.from == $0.to })
    }

    func testDoesNotRewriteSubstrateInstallName() {
        let changes = JailbreakDependencyRewriter.planRewrites(
            for: [
                "@executable_path/Frameworks/libsubstrate.dylib",
                "/usr/lib/libSystem.B.dylib"
            ],
            binary: app.appendingPathComponent("Frameworks/libsubstrate.dylib"),
            app: app,
            mainExecutable: main,
            mode: .bundledStub,
            installName: "@executable_path/Frameworks/libsubstrate.dylib"
        )
        XCTAssertTrue(changes.isEmpty)
    }

    func testDoesNotRewriteIOSSystemFrameworks() {
        XCTAssertNil(
            JailbreakDependencyRewriter.genericRewriteTarget(
                for: "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration"
            )
        )
        XCTAssertNil(
            JailbreakDependencyRewriter.genericRewriteTarget(
                for: "/System/Library/PrivateFrameworks/SpringBoard.framework/SpringBoard"
            )
        )
        let changes = JailbreakDependencyRewriter.planRewrites(
            for: [
                "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration",
                "/usr/lib/libSystem.B.dylib",
                "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"
            ],
            binary: plugin,
            app: app,
            mainExecutable: main,
            mode: .bundledStub
        )
        XCTAssertEqual(changes.map(\.from), ["/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate"])
        XCTAssertFalse(changes.contains { $0.from.contains("SystemConfiguration") })
    }

    func testGenericRewriteLeavesThemeBoxAsPluginIdentity() {
        let id = "/Library/MobileSubstrate/DynamicLibraries/ThemeBox.dylib"
        let changes = JailbreakDependencyRewriter.planRewrites(
            for: [id, "/usr/lib/libSystem.B.dylib"],
            binary: plugin,
            app: app,
            mainExecutable: main,
            mode: .bundledStub,
            installName: id
        )
        XCTAssertEqual(changes, [InstallNameChange(from: id, to: "@rpath/ThemeBox.dylib")])
    }

    func testBundledStubIsPartOfModuleResources() {
        XCTAssertNotNil(JailbreakDependencyRewriter.bundledStubURL())
    }

    func testPreferredFrameworkHostFailsWhenMissing() throws {
        for tool in [ExternalTool.clang, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "preferred-host-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Demo",
                "CFBundleIdentifier": "com.example.demo"
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", app.appendingPathComponent("Demo").path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        let plugin = root.appendingPathComponent("Plug.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path]
        ).succeeded)
        XCTAssertThrowsError(
            try IpaInjectionWorkflow.preflight(
                InjectionPlan(
                    input: .app(app),
                    items: [InjectionItem(dylibURL: plugin, target: .preferredFrameworkHost)],
                    signing: .none
                )
            )
        ) { error in
            guard case IpaInjectionWorkflowError.targetNotFound = error else {
                return XCTFail("应为 targetNotFound，得到 \(error)")
            }
        }
    }

    func testRewriteOffLeavesUsrLibSubstrateAndSkipsStub() throws {
        for tool in [ExternalTool.clang, .otool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "rewrite-off")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Demo",
                "CFBundleIdentifier": "com.example.demo"
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", app.appendingPathComponent("Demo").path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        let plugin = root.appendingPathComponent("Tweak.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        _ = try DylibInjector.inject(
            dylibPath: "/usr/lib/libsubstrate.dylib",
            intoFileAt: plugin,
            stripCodeSignature: true
        )
        let output = root.appendingPathComponent("Out.app")
        _ = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: .app(app),
                items: [InjectionItem(dylibURL: plugin)],
                signing: .none,
                rewriteJailbreakDependencies: false
            ),
            outputURL: output
        )
        let deps = try DylibService.loadDependencyPaths(
            fileAt: output.appendingPathComponent("Frameworks/Tweak.dylib")
        )
        XCTAssertTrue(deps.contains("/usr/lib/libsubstrate.dylib"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Frameworks/libsubstrate.dylib").path
        ))
    }

    func testNativeFrameworkModeDoesNotCopyStub() throws {
        for tool in [ExternalTool.clang, .otool, .installNameTool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "native-cs")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Demo.app")
        let cs = app.appendingPathComponent("Frameworks/CydiaSubstrate.framework")
        try FileManager.default.createDirectory(at: cs, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "Demo",
                "CFBundleIdentifier": "com.example.demo"
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", app.appendingPathComponent("Demo").path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            [
                "-dynamiclib", "-o", cs.appendingPathComponent("CydiaSubstrate").path,
                source.path, "-Wl,-headerpad,0x1000"
            ]
        ).succeeded)
        let plugin = root.appendingPathComponent("Tweak.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        _ = try DylibInjector.inject(
            dylibPath: "/usr/lib/libsubstrate.dylib",
            intoFileAt: plugin,
            stripCodeSignature: true
        )
        let output = root.appendingPathComponent("Out.app")
        _ = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: .app(app),
                items: [InjectionItem(dylibURL: plugin)],
                signing: .none
            ),
            outputURL: output
        )
        let deps = try DylibService.loadDependencyPaths(
            fileAt: output.appendingPathComponent("Frameworks/Tweak.dylib")
        )
        XCTAssertTrue(deps.contains("@rpath/CydiaSubstrate.framework/CydiaSubstrate"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("Frameworks/libsubstrate.dylib").path
        ))
        let rpaths = try DylibService.rpaths(fileAt: output.appendingPathComponent("Frameworks/Tweak.dylib"))
        XCTAssertTrue(rpaths.contains("@executable_path/Frameworks"))
    }

    /// 只改注入的插件，不扫小组件。injectipa 也是这个范围。
    func testDoesNotRewriteUnrelatedAppExtension() throws {
        for tool in [ExternalTool.clang, .otool, .installNameTool] where !tool.isAvailable {
            throw XCTSkip("缺少 \(tool.commandName)")
        }
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "rewrite-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("WeChat.app")
        let appex = app.appendingPathComponent("PlugIns/Widget.appex")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": "WeChat",
                "CFBundleIdentifier": "com.tencent.xin"
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("source.c")
        try "int main(void) { return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", app.appendingPathComponent("WeChat").path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        let extensionBinary = appex.appendingPathComponent("Widget")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-o", extensionBinary.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        _ = try DylibInjector.inject(
            dylibPath: "/usr/lib/libsubstrate.dylib",
            intoFileAt: extensionBinary,
            stripCodeSignature: true
        )
        let plugin = root.appendingPathComponent("WCRefine.dylib")
        XCTAssertTrue(try Shell.run(
            ExternalTool.clang.path!,
            ["-dynamiclib", "-o", plugin.path, source.path, "-Wl,-headerpad,0x1000"]
        ).succeeded)
        _ = try DylibInjector.inject(
            dylibPath: "/usr/lib/libsubstrate.dylib",
            intoFileAt: plugin,
            stripCodeSignature: true
        )
        let output = root.appendingPathComponent("Out.app")
        _ = try IpaInjectionWorkflow.execute(
            InjectionPlan(
                input: .app(app),
                items: [InjectionItem(dylibURL: plugin)],
                signing: .none
            ),
            outputURL: output
        )
        let pluginDeps = try DylibService.loadDependencyPaths(
            fileAt: output.appendingPathComponent("Frameworks/WCRefine.dylib")
        )
        XCTAssertTrue(pluginDeps.contains("@loader_path/libsubstrate.dylib"))
        let extensionDeps = try DylibService.loadDependencyPaths(
            fileAt: output.appendingPathComponent("PlugIns/Widget.appex/Widget")
        )
        XCTAssertTrue(extensionDeps.contains("/usr/lib/libsubstrate.dylib"))
    }
}

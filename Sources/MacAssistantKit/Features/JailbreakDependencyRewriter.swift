import Foundation

/// 侧载时把越狱绝对路径改成包内可解析路径。
///
/// Substrate 变体（`CydiaSubstrate` / `libsubstrate*`）必须收成**同一个**落地文件：
/// - 包内已有 `CydiaSubstrate.framework`（或用户拖入 ElleKit）→ 改到 `@rpath/CydiaSubstrate.framework/CydiaSubstrate`
/// - 否则拷贝内置 `libsubstrate.dylib` 到 `Frameworks/`，按二进制位置选 `@rpath` 或 `@loader_path`
///
/// 内置 stub **不是**再 LC_LOAD 进主程序的插件，只给其它 Mach-O 当依赖。
public enum JailbreakDependencyRewriter {

    public enum SubstrateMode: String, Codable, Hashable, Sendable {
        case bundledStub
        case nativeFramework
    }

    public static let stubFileName = "libsubstrate.dylib"
    public static let nativeFrameworkPath = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
    public static let mainExecutableStubPath = "@rpath/libsubstrate.dylib"
    public static let frameworksSiblingStubPath = "@loader_path/libsubstrate.dylib"

    public static func isCydiaSubstrate(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("cydiasubstrate") { return true }
        if lower.hasSuffix("libsubstrate.dylib") { return true }
        if lower.contains("libsubstrate.") && lower.hasSuffix(".dylib") { return true }
        return false
    }

    /// 插件 / 宿主二进制是否应跳过 Substrate 改写（它自己就是运行库）。
    public static func isSubstrateRuntimeFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == stubFileName { return true }
        if name == "CydiaSubstrate",
           url.deletingLastPathComponent().lastPathComponent == "CydiaSubstrate.framework" {
            return true
        }
        return false
    }

    public static func bundledStubURL() -> URL? {
        Bundle.module.url(forResource: "libsubstrate", withExtension: "dylib")
    }

    public static func hasNativeCydiaSubstrateFramework(in app: URL) -> Bool {
        let directories = ["Frameworks", "Contents/Frameworks"]
        for directory in directories {
            let binary = app
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("CydiaSubstrate.framework", isDirectory: true)
                .appendingPathComponent("CydiaSubstrate")
            if MachOIdentifier.isMachO(fileAt: binary) { return true }
        }
        return false
    }

    public static func mode(
        app: URL,
        resources: [InjectionResource] = []
    ) -> SubstrateMode {
        if hasNativeCydiaSubstrateFramework(in: app) { return .nativeFramework }
        let providesFramework = resources.contains {
            $0.destination.rawValue.lowercased().contains("cydiasubstrate.framework")
        }
        return providesFramework ? .nativeFramework : .bundledStub
    }

    public static func substrateTarget(
        for original: String,
        binary: URL,
        app: URL,
        mainExecutable: URL,
        mode: SubstrateMode
    ) -> String? {
        guard isCydiaSubstrate(original) else { return nil }
        let target: String
        switch mode {
        case .nativeFramework:
            target = nativeFrameworkPath
        case .bundledStub:
            target = stubLoadPath(for: binary, app: app, mainExecutable: mainExecutable)
        }
        return original == target ? nil : target
    }

    /// 主程序用短 `@rpath`（少占 header padding）；`Frameworks/*.dylib` 用 `@loader_path` 同级解析，不依赖 rpath。
    public static func stubLoadPath(for binary: URL, app: URL, mainExecutable: URL) -> String {
        if binary.standardizedFileURL == mainExecutable.standardizedFileURL {
            return mainExecutableStubPath
        }
        let parent = binary.deletingLastPathComponent()
        if binary.pathExtension.lowercased() == "dylib",
           parent.lastPathComponent == "Frameworks" {
            return frameworksSiblingStubPath
        }
        if parent.pathExtension.lowercased() == "framework" {
            return "@loader_path/../\(stubFileName)"
        }
        return mainExecutableStubPath
    }

    public static func rpathNeededToResolveStub(for binary: URL, app: URL, mainExecutable: URL) -> String? {
        if binary.standardizedFileURL == mainExecutable.standardizedFileURL {
            return macOSFrameworksRPath(in: app) ?? "@executable_path/Frameworks"
        }
        let parent = binary.deletingLastPathComponent()
        if binary.pathExtension.lowercased() == "dylib", parent.lastPathComponent == "Frameworks" {
            return nil
        }
        if parent.pathExtension.lowercased() == "framework" {
            return nil
        }
        if parent.pathExtension.lowercased() == "appex" {
            return "@executable_path/../../Frameworks"
        }
        return macOSFrameworksRPath(in: app) ?? "@executable_path/Frameworks"
    }

    public static func rpathNeededToResolveNativeFramework(for binary: URL, app: URL, mainExecutable: URL) -> String {
        if binary.standardizedFileURL == mainExecutable.standardizedFileURL {
            return macOSFrameworksRPath(in: app) ?? "@executable_path/Frameworks"
        }
        if binary.deletingLastPathComponent().pathExtension.lowercased() == "appex" {
            return "@executable_path/../../Frameworks"
        }
        return macOSFrameworksRPath(in: app) ?? "@executable_path/Frameworks"
    }

    /// 非 Substrate 的越狱路径（Cephei、libhooker 等）仍改成 `@rpath/<basename>`。
    public static func genericRewriteTarget(for dependency: String) -> String? {
        if dependency.hasPrefix("@"), !isCydiaSubstrate(dependency) { return nil }
        var path = dependency
        if path.hasPrefix("/var/jb") { path = String(path.dropFirst("/var/jb".count)) }
        if isCydiaSubstrate(path) { return nil }
        if path.contains("CydiaSubstrate.framework") {
            return nativeFrameworkPath
        }
        if let range = path.range(of: "/Library/Frameworks/") {
            return "@rpath/" + String(path[range.upperBound...])
        }
        if path.contains("/Library/MobileSubstrate/DynamicLibraries/") {
            return "@rpath/" + (path as NSString).lastPathComponent
        }
        if path.hasPrefix("/Library/"), path.hasSuffix(".dylib") {
            return "@rpath/" + (path as NSString).lastPathComponent
        }
        if path.hasPrefix("/usr/lib/"), path.hasSuffix(".dylib") {
            let base = (path as NSString).lastPathComponent.lowercased()
            if DependencyClassifier.matchesJailbreakKeyword(base) {
                return "@rpath/" + (path as NSString).lastPathComponent
            }
        }
        return nil
    }

    public static func planRewrites(
        for dependencies: [String],
        binary: URL,
        app: URL,
        mainExecutable: URL,
        mode: SubstrateMode,
        installName: String? = nil
    ) -> [InstallNameChange] {
        let loadPaths = installName.map { id in dependencies.filter { $0 != id } } ?? dependencies
        var seen = Set<String>()
        var result: [InstallNameChange] = []
        for dependency in loadPaths {
            let target = substrateTarget(
                for: dependency,
                binary: binary,
                app: app,
                mainExecutable: mainExecutable,
                mode: mode
            ) ?? genericRewriteTarget(for: dependency)
            guard let target, target != dependency, seen.insert(dependency).inserted else { continue }
            result.append(InstallNameChange(from: dependency, to: target))
        }
        if let installName,
           !isCydiaSubstrate(installName),
           let target = genericRewriteTarget(for: installName),
           target != installName,
           seen.insert(installName).inserted {
            result.append(InstallNameChange(from: installName, to: target))
        }
        return result
    }

    private static func macOSFrameworksRPath(in app: URL) -> String? {
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        return FileSystemHelper.isDirectory(macOS) ? "@executable_path/../Frameworks" : nil
    }
}

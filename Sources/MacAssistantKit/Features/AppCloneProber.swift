import Foundation

public enum AppCloneProber {
    public static func inspect(_ url: URL) throws -> AppCloneInfo {
        guard url.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(url) else {
            throw AppCloneError.invalidApp
        }
        let plist = try IpaService.infoPlist(appBundle: url)
        let bundleID = (plist["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bundleID.isEmpty else { throw AppCloneError.invalidApp }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let executableName = (plist["CFBundleExecutable"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let macos = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let executable = macos.appendingPathComponent(executableName)
        let wrapper = url.appendingPathComponent("Wrapper", isDirectory: true)
        let platform = ((plist["DTPlatformName"] as? String) ?? "").lowercased()
        let isIOS = FileSystemHelper.isDirectory(wrapper)
            || platform.contains("iphone")
            || platform.contains("ipad")
            || !FileSystemHelper.isDirectory(macos)
        let entitlements = (try? SigningService.signedEntitlements(at: url)) ?? [:]
        let sandboxed = boolValue(entitlements["com.apple.security.app-sandbox"])
        return AppCloneInfo(
            url: url,
            name: name,
            bundleID: bundleID,
            executable: executable,
            hasSandbox: sandboxed,
            isIOSApp: isIOS
        )
    }

    public static func probe(_ url: URL) throws -> AppCloneProbe {
        let info = try inspect(url)
        if AppCloneRecipes.isBlocked(info.bundleID) {
            throw AppCloneError.blockedApp(info.name)
        }
        if info.isIOSApp {
            throw AppCloneError.iosApp
        }
        let frameworks = detectFrameworks(in: url)
        let kind = detectKind(bundleID: info.bundleID, frameworks: frameworks, app: url)
        if let builtin = AppCloneRecipes.recipe(forBundleID: info.bundleID) {
            return AppCloneProbe(
                info: info,
                kind: builtin.kind,
                recipe: builtin,
                matchedBuiltin: true,
                frameworks: frameworks,
                reason: L("appclone.probe.builtin", builtin.appName)
            )
        }
        let generated = generatedRecipe(for: info, kind: kind)
        return AppCloneProbe(
            info: info,
            kind: kind,
            recipe: generated,
            matchedBuiltin: false,
            frameworks: frameworks,
            reason: generatedReason(kind: kind, sandboxed: info.hasSandbox, recipe: generated)
        )
    }

    public static func detectKind(bundleID: String, frameworks: [String], app: URL) -> AppCloneKind {
        let id = bundleID.lowercased()
        let names = frameworks.map { $0.lowercased() }
        if names.contains(where: { $0.contains("electron") })
            || ["electron", "vscode", "slack", "discord", "lark", "notion"].contains(where: { id.contains($0) }) {
            return .electron
        }
        if names.contains(where: { $0.contains("chromium") || $0.contains("google chrome") })
            || ["chrome", "chromium", "microsoft.edge", "arc", "brave"].contains(where: { id.contains($0) }) {
            return .chromium
        }
        if names.contains(where: { $0.contains("xul") }) || id.contains("firefox") || id.contains("torbrowser") {
            return .firefox
        }
        if FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) {
            return .cocoa
        }
        return .generic
    }

    public static func detectFrameworks(in app: URL) -> [String] {
        let directory = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard FileSystemHelper.isDirectory(directory) else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".framework") || $0.hasSuffix(".dylib") }
            .sorted()
    }

    public static func dataDirectoryArgument(in executable: URL) -> [String] {
        guard FileManager.default.isReadableFile(atPath: executable.path) else { return [] }
        let data = (try? Data(contentsOf: executable, options: [.mappedIfSafe])) ?? Data()
        let sample = data.prefix(15_000_000)
        let candidates: [(needle: String, arguments: [String])] = [
            ("--user-data-dir", ["--user-data-dir={{CLONE_DATA_DIR}}"]),
            ("--data-dir", ["--data-dir={{CLONE_DATA_DIR}}"]),
            ("--datadir", ["--datadir={{CLONE_DATA_DIR}}"]),
            ("-profile", ["-profile", "{{CLONE_DATA_DIR}}"]),
            ("--profile", ["--profile={{CLONE_DATA_DIR}}"]),
            ("--config-dir", ["--config-dir={{CLONE_DATA_DIR}}"]),
            ("--config-path", ["--config-path={{CLONE_DATA_DIR}}"]),
            ("--storage-path", ["--storage-path={{CLONE_DATA_DIR}}"]),
            ("--app-data", ["--app-data={{CLONE_DATA_DIR}}"]),
        ]
        for candidate in candidates where containsASCII(candidate.needle, in: sample) {
            return candidate.arguments
        }
        return []
    }

    private static func generatedRecipe(for info: AppCloneInfo, kind: AppCloneKind) -> AppCloneRecipe {
        switch kind {
        case .chromium, .electron:
            return AppCloneRecipe(
                bundleID: info.bundleID,
                appName: info.name,
                strategy: .soft,
                kind: kind,
                launchArguments: ["--user-data-dir={{CLONE_DATA_DIR}}"]
            )
        case .firefox:
            return AppCloneRecipe(
                bundleID: info.bundleID,
                appName: info.name,
                strategy: .soft,
                kind: kind,
                launchArguments: ["-profile", "{{CLONE_DATA_DIR}}"]
            )
        case .cocoa, .generic:
            let arguments = dataDirectoryArgument(in: info.executable)
            if !arguments.isEmpty {
                return AppCloneRecipe(
                    bundleID: info.bundleID,
                    appName: info.name,
                    strategy: info.hasSandbox ? .hard : .soft,
                    kind: kind,
                    stripSandbox: info.hasSandbox,
                    launchArguments: arguments
                )
            }
            return AppCloneRecipe(
                bundleID: info.bundleID,
                appName: info.name,
                strategy: .hard,
                kind: kind,
                stripSandbox: info.hasSandbox,
                environment: [
                    "HOME": "{{CLONE_DATA_DIR}}/Home",
                    "TMPDIR": "{{CLONE_DATA_DIR}}/Tmp",
                ],
                symlinkWhitelist: ["Library/Keychains"]
            )
        }
    }

    private static func generatedReason(kind: AppCloneKind, sandboxed: Bool, recipe: AppCloneRecipe) -> String {
        if !recipe.launchArguments.isEmpty {
            return L("appclone.probe.cli", recipe.launchArguments.joined(separator: " "))
        }
        switch kind {
        case .chromium, .electron:
            return L("appclone.probe.chromium")
        case .firefox:
            return L("appclone.probe.firefox")
        case .cocoa, .generic:
            return sandboxed ? L("appclone.probe.sandboxed") : L("appclone.probe.native")
        }
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    private static func containsASCII(_ needle: String, in data: Data) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }
}

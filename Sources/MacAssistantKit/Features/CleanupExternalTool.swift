import Foundation

/// 不能跟普通缓存一起进废纸篓的外部命令。只预览与单独确认后执行。
/// 包管理器同时允许废纸篓清理；有 CLI 时多一个「单独执行」走官方命令。
public enum CleanupExternalTool: String, Sendable, CaseIterable {
    case homebrew
    case simulatorRuntimes = "simulator-runtimes"
    case npm
    case yarn
    case pnpm
    case pip
    case uv
    case cocoapods
    case bun
    case deno
    case goBuild = "go-build"
    case goModules = "go-modules"

    public init?(targetID: String) {
        self.init(rawValue: targetID)
    }

    public var targetID: String { rawValue }

    public var requiresIsolation: Bool {
        switch self {
        case .homebrew, .simulatorRuntimes:
            return true
        case .npm, .yarn, .pnpm, .pip, .uv, .cocoapods, .bun, .deno, .goBuild, .goModules:
            return false
        }
    }

    /// 不要在 SwiftUI `body` 里同步调用。包管理器探测会查 PATH，
    /// 必须放到后台快照里，避免渲染期卡住或重入 AttributeGraph。
    public var isAvailable: Bool {
        switch self {
        case .homebrew, .simulatorRuntimes:
            return true
        case .npm:
            return Shell.which("npm") != nil
        case .yarn:
            return Shell.which("yarn") != nil
        case .pnpm:
            return Shell.which("pnpm") != nil
        case .pip:
            return Shell.which("pip3") != nil || Shell.which("pip") != nil
        case .uv:
            return Shell.which("uv") != nil
        case .cocoapods:
            return Shell.which("pod") != nil
        case .bun:
            return Shell.which("bun") != nil
        case .deno:
            return Shell.which("deno") != nil
        case .goBuild, .goModules:
            return Shell.which("go") != nil
        }
    }

    public var commandPreview: String {
        switch self {
        case .homebrew:
            return "brew cleanup -s"
        case .simulatorRuntimes:
            return "xcrun simctl runtime delete unavailable"
        case .npm:
            return "npm cache clean --force"
        case .yarn:
            return "yarn cache clean"
        case .pnpm:
            return "pnpm store prune"
        case .pip:
            return "pip3 cache purge"
        case .uv:
            return "uv cache clean"
        case .cocoapods:
            return "pod cache clean --all"
        case .bun:
            return "bun pm cache rm"
        case .deno:
            return "deno clean"
        case .goBuild:
            return "go clean -cache"
        case .goModules:
            return "go clean -modcache"
        }
    }

    public func run() throws -> CommandResult {
        switch self {
        case .homebrew:
            return try Shell.run(Self.resolveBrew(), ["cleanup", "-s"])
        case .simulatorRuntimes:
            return try Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", "unavailable"])
        case .npm:
            return try Shell.run(Self.requireTool("npm"), ["cache", "clean", "--force"])
        case .yarn:
            return try Shell.run(Self.requireTool("yarn"), ["cache", "clean"])
        case .pnpm:
            return try Shell.run(Self.requireTool("pnpm"), ["store", "prune"])
        case .pip:
            return try Shell.run(Self.requireTool("pip3", fallback: "pip"), ["cache", "purge"])
        case .uv:
            return try Shell.run(Self.requireTool("uv"), ["cache", "clean"])
        case .cocoapods:
            return try Shell.run(Self.requireTool("pod"), ["cache", "clean", "--all"])
        case .bun:
            return try Shell.run(Self.requireTool("bun"), ["pm", "cache", "rm"])
        case .deno:
            return try Shell.run(Self.requireTool("deno"), ["clean"])
        case .goBuild:
            return try Shell.run(Self.requireTool("go"), ["clean", "-cache"])
        case .goModules:
            return try Shell.run(Self.requireTool("go"), ["clean", "-modcache"])
        }
    }

    private static func requireTool(_ name: String, fallback: String? = nil) throws -> String {
        if let path = Shell.which(name) { return path }
        if let fallback, let path = Shell.which(fallback) { return path }
        throw NSError(
            domain: "CleanupExternalTool",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: L("cleanup.error.tool-missing", name)]
        )
    }

    public static func resolveBrew(
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> String {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if let path = candidates.first(where: fileExists) { return path }
        throw NSError(
            domain: "CleanupExternalTool",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: L("cleanup.error.brew-missing")]
        )
    }
}

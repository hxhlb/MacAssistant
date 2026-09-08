import Foundation

/// 硬安全拒绝名单：扫描与执行都必须挡，且不能被 UI / 用户配置关掉。
///
/// 同时检查路径字面值与 symlink 解析后的路径；CloudDocs 的 `com~apple~` 域名也拒。
public enum CleanupDeniedPaths: Sendable {
    /// 相对用户主目录的受保护前缀（目录本身及其子项）。
    public static let relativePrefixes: [String] = [
        "Documents",
        "Desktop",
        "Downloads",
        ".ssh",
        ".gnupg",
        "Library/Mail",
        "Library/Messages",
        "Library/Mobile Documents",
        "Library/CloudStorage",
        "Library/Application Support/FileProvider",
        "Library/Application Support/CloudDocs",
        "Library/Daemon Containers",
        "Library/Caches/CloudKit",
        "Library/Caches/com.apple.bird",
        "Library/Caches/com.apple.cloudkit",
        "Library/Caches/com.apple.cloudd",
        "Library/Caches/com.apple.FileProvider",
        "Library/Caches/com.apple.FontRegistry",
        "Library/Caches/com.apple.Spotlight",
        "Library/Caches/Homebrew",
        "Library/Caches/pypoetry",
        "Library/Caches/pypoetry/virtualenvs",
        ".cache/pypoetry",
        ".cache/pypoetry/virtualenvs"
    ]

    /// 任意层级出现这些路径分量即拒绝（Mole 额外保护）。
    public static let deniedPathComponents: Set<String> = [
        "com.apple.FontRegistry",
        "com.apple.Spotlight",
        "com.apple.bird",
        "com.apple.cloudkit",
        "com.apple.cloudd",
        "com.apple.FileProvider",
        "pypoetry"
    ]

    public static func contains(_ url: URL, homeDirectory: URL) -> Bool {
        let home = homeDirectory.standardizedFileURL
        let requested = url.standardizedFileURL
        if matches(requested, home: home) { return true }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path != requested.path {
            return matches(resolved, home: home)
        }
        return false
    }

    private static func matches(_ url: URL, home: URL) -> Bool {
        let components = url.pathComponents
        if components.contains(where: { $0.contains("com~apple~") }) {
            return true
        }
        if components.contains(where: { deniedPathComponents.contains($0) }) {
            return true
        }
        if containsPoetryVirtualenvs(components) {
            return true
        }

        let homeComponents = home.pathComponents
        guard components.starts(with: homeComponents), components.count > homeComponents.count else {
            return false
        }
        let relative = components.dropFirst(homeComponents.count)
        for prefix in relativePrefixes {
            let prefixComponents = prefix.split(separator: "/").map(String.init)
            if relative.starts(with: prefixComponents) {
                return true
            }
        }
        if relative.contains("CloudKit") {
            return true
        }
        return false
    }

    private static func containsPoetryVirtualenvs(_ components: [String]) -> Bool {
        for index in components.indices.dropLast() {
            if components[index] == "pypoetry", components[index + 1] == "virtualenvs" {
                return true
            }
        }
        return false
    }
}

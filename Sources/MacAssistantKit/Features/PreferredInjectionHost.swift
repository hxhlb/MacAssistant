import Foundation

/// 微信等自签包的**可选**注入宿主：有 `ProtobufLite3` 用 3，否则 2，再否则 `ProtobufLite`。
/// 这是某一个 dylib 的显式指定，绝不是工作台默认。没指定就只打主程序，不碰 Frameworks。
/// 指定某一档找不到就失败，不自动降级。
/// 主程序和 `WeChatShareExtensionNew` 都 `@rpath` 链同一份 framework
///（扩展还有 `@executable_path/../../Frameworks`），打一次两边都会加载，不必再改 appex 二进制。
public enum PreferredInjectionHost {
    public static let rankedNames = ["ProtobufLite3", "ProtobufLite2", "ProtobufLite"]

    /// 某个 dylib 的宿主选择。`automatic` = 未指定 = 主程序。
    /// `preferredFramework` = 可选的 3 → 2 → ProtobufLite，只对点过的那一个 dylib 生效。
    public enum Choice: String, Codable, CaseIterable, Hashable, Sendable {
        case automatic
        case preferredFramework
        case protobufLite3 = "ProtobufLite3"
        case protobufLite2 = "ProtobufLite2"
        case protobufLite = "ProtobufLite"

        public var frameworkName: String? {
            switch self {
            case .automatic, .preferredFramework: return nil
            case .protobufLite3, .protobufLite2, .protobufLite: return rawValue
            }
        }

        public var usesPreferredFrameworkHost: Bool { self == .preferredFramework }

        var searchNames: [String] {
            switch self {
            case .automatic: return []
            case .preferredFramework: return PreferredInjectionHost.rankedNames
            case .protobufLite3, .protobufLite2, .protobufLite: return [rawValue]
            }
        }
    }

    public static func relativePath(in app: URL, preferring choice: Choice = .preferredFramework) -> String? {
        for name in choice.searchNames {
            if let path = candidate(named: name, in: app) {
                return path
            }
        }
        return nil
    }

    public static func url(in app: URL, preferring choice: Choice = .preferredFramework) -> URL? {
        relativePath(in: app, preferring: choice).map { app.appendingPathComponent($0) }
    }

    private static func candidate(named name: String, in app: URL) -> String? {
        let directories = ["Frameworks", "Contents/Frameworks"]
        for directory in directories {
            let folder = app.appendingPathComponent(directory, isDirectory: true)
            let framework = folder.appendingPathComponent("\(name).framework", isDirectory: true)
            if FileSystemHelper.isDirectory(framework) {
                let plist = (try? IpaService.infoPlist(appBundle: framework)) ?? [:]
                let executable = (plist["CFBundleExecutable"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
                let file = framework.appendingPathComponent(executable)
                if MachOIdentifier.isMachO(fileAt: file) {
                    return relativePath(file, under: app)
                }
            }
            let bare = folder.appendingPathComponent(name)
            if MachOIdentifier.isMachO(fileAt: bare) {
                return relativePath(bare, under: app)
            }
        }
        return nil
    }

    private static func relativePath(_ url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }
}

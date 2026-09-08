import Foundation

public enum AppCloneStrategy: String, Codable, CaseIterable, Sendable {
    case hard
    case soft

    public var label: String { L("appclone.strategy.\(rawValue)") }
}

public enum AppCloneKind: String, Codable, CaseIterable, Sendable {
    case cocoa
    case chromium
    case electron
    case firefox
    case generic

    public var label: String { L("appclone.kind.\(rawValue)") }
}

public enum AppCloneInjection: String, Codable, CaseIterable, Sendable {
    case auto
    case dylib
    case launcher

    public var label: String { L("appclone.injection.\(rawValue)") }
}

public enum AppCloneProxyKind: String, Codable, CaseIterable, Sendable {
    case http
    case https
    case socks5

    public var label: String { rawValue.uppercased() }
}

public struct AppCloneProxy: Hashable, Codable, Sendable {
    public var kind: AppCloneProxyKind
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var noProxy: String

    public init(
        kind: AppCloneProxyKind = .http,
        host: String = "127.0.0.1",
        port: Int = 7890,
        username: String = "",
        password: String = "",
        noProxy: String = "localhost,127.0.0.1,*.local"
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.noProxy = noProxy
    }

    public var urlString: String {
        let auth = username.isEmpty ? "" : "\(username):\(password)@"
        return "\(kind.rawValue)://\(auth)\(host):\(port)"
    }
}

public struct AppCloneRecipe: Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var strategy: AppCloneStrategy
    public var kind: AppCloneKind
    public var stripSandbox: Bool
    public var stripURLSchemes: Bool
    public var environment: [String: String]
    public var launchArguments: [String]
    public var symlinkWhitelist: [String]

    public init(
        bundleID: String,
        appName: String,
        strategy: AppCloneStrategy,
        kind: AppCloneKind,
        stripSandbox: Bool = false,
        stripURLSchemes: Bool = false,
        environment: [String: String] = [:],
        launchArguments: [String] = [],
        symlinkWhitelist: [String] = []
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.strategy = strategy
        self.kind = kind
        self.stripSandbox = stripSandbox
        self.stripURLSchemes = stripURLSchemes
        self.environment = environment
        self.launchArguments = launchArguments
        self.symlinkWhitelist = symlinkWhitelist
    }

    public var isolatesData: Bool {
        launchArguments.contains { $0.contains(AppCloneToken.dataDirectory) }
            || environment.values.contains { $0.contains(AppCloneToken.dataDirectory) }
    }
}

public enum AppCloneToken {
    public static let dataDirectory = "{{CLONE_DATA_DIR}}"
}

public struct AppCloneInfo: Hashable, Sendable {
    public var url: URL
    public var name: String
    public var bundleID: String
    public var executable: URL
    public var hasSandbox: Bool
    public var isIOSApp: Bool

    public init(
        url: URL,
        name: String,
        bundleID: String,
        executable: URL,
        hasSandbox: Bool,
        isIOSApp: Bool
    ) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.executable = executable
        self.hasSandbox = hasSandbox
        self.isIOSApp = isIOSApp
    }
}

public struct AppCloneProbe: Hashable, Sendable {
    public var info: AppCloneInfo
    public var kind: AppCloneKind
    public var recipe: AppCloneRecipe
    public var matchedBuiltin: Bool
    public var frameworks: [String]
    public var reason: String

    public init(
        info: AppCloneInfo,
        kind: AppCloneKind,
        recipe: AppCloneRecipe,
        matchedBuiltin: Bool,
        frameworks: [String],
        reason: String
    ) {
        self.info = info
        self.kind = kind
        self.recipe = recipe
        self.matchedBuiltin = matchedBuiltin
        self.frameworks = frameworks
        self.reason = reason
    }
}

public struct AppCloneRequest: Sendable {
    public var source: URL
    public var cloneName: String
    public var displayName: String
    public var bundleID: String
    public var strategy: AppCloneStrategy?
    public var injection: AppCloneInjection
    public var proxy: AppCloneProxy?
    public var outputDirectory: URL?
    public var dataDirectory: URL?
    public var bundlePrep: AppCloneBundlePrep

    public init(
        source: URL,
        cloneName: String,
        displayName: String,
        bundleID: String,
        strategy: AppCloneStrategy? = nil,
        injection: AppCloneInjection = .auto,
        proxy: AppCloneProxy? = nil,
        outputDirectory: URL? = nil,
        dataDirectory: URL? = nil,
        bundlePrep: AppCloneBundlePrep = .isolatedDefaults
    ) {
        self.source = source
        self.cloneName = cloneName
        self.displayName = displayName
        self.bundleID = bundleID
        self.strategy = strategy
        self.injection = injection
        self.proxy = proxy
        self.outputDirectory = outputDirectory
        self.dataDirectory = dataDirectory
        self.bundlePrep = bundlePrep
    }
}

public struct AppCloneRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var displayName: String
    public var sourcePath: String
    public var sourceBundleID: String
    public var clonePath: String
    public var dataPath: String
    public var bundleID: String
    public var strategy: AppCloneStrategy
    public var kind: AppCloneKind
    public var injection: AppCloneInjection
    public var recipeName: String
    public var createdAt: Date
    public var updatedAt: Date
    public var proxy: AppCloneProxy?

    public init(
        id: UUID = UUID(),
        name: String,
        displayName: String,
        sourcePath: String,
        sourceBundleID: String,
        clonePath: String,
        dataPath: String,
        bundleID: String,
        strategy: AppCloneStrategy,
        kind: AppCloneKind,
        injection: AppCloneInjection,
        recipeName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        proxy: AppCloneProxy? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.sourceBundleID = sourceBundleID
        self.clonePath = clonePath
        self.dataPath = dataPath
        self.bundleID = bundleID
        self.strategy = strategy
        self.kind = kind
        self.injection = injection
        self.recipeName = recipeName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.proxy = proxy
    }

    public var cloneURL: URL { URL(fileURLWithPath: clonePath) }
    public var dataURL: URL { URL(fileURLWithPath: dataPath) }
    public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    public var cloneExists: Bool { FileManager.default.fileExists(atPath: clonePath) }
    public var sourceExists: Bool { FileManager.default.fileExists(atPath: sourcePath) }
}

public struct AppClonePaths: Hashable, Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var `default`: AppClonePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return AppClonePaths(
            root: home.appendingPathComponent("Library/Application Support/Mac小助手/AppClones", isDirectory: true)
        )
    }

    public var apps: URL { root.appendingPathComponent("Apps", isDirectory: true) }
    public var data: URL { root.appendingPathComponent("Data", isDirectory: true) }
    public var registry: URL { root.appendingPathComponent("clones.json") }
    public var helpers: URL { root.appendingPathComponent("Helpers", isDirectory: true) }

    public static var userApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }
}

public enum AppCloneError: LocalizedError, Equatable, Sendable {
    case invalidApp
    case iosApp
    case blockedApp(String)
    case invalidName
    case invalidBundleID
    case outputExists(String)
    case sourceMissing
    case cloneMissing
    case helperBuildFailed(String)
    case codesignFailed(String)
    case invalidProxy

    public var errorDescription: String? {
        switch self {
        case .invalidApp: return L("appclone.error.invalidApp")
        case .iosApp: return L("appclone.error.iosApp")
        case let .blockedApp(name): return L("appclone.error.blockedApp", name)
        case .invalidName: return L("appclone.error.invalidName")
        case .invalidBundleID: return L("appclone.error.invalidBundleID")
        case let .outputExists(path): return L("appclone.error.outputExists", path)
        case .sourceMissing: return L("appclone.error.sourceMissing")
        case .cloneMissing: return L("appclone.error.cloneMissing")
        case let .helperBuildFailed(detail): return L("appclone.error.helperBuildFailed", detail)
        case let .codesignFailed(detail): return L("appclone.error.codesignFailed", detail)
        case .invalidProxy: return L("appclone.error.invalidProxy")
        }
    }
}

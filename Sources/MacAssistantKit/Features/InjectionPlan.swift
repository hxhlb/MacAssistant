import Foundation

public struct ValidatedRelativePath: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }

    public init(_ value: String) throws {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains("\0"),
              normalized.range(of: #"^[A-Za-z]:"# , options: .regularExpression) == nil
        else {
            throw InjectionPlanError.invalidRelativePath(value)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw InjectionPlanError.invalidRelativePath(value)
        }
        rawValue = components.joined(separator: "/")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum InjectionInput: Codable, Hashable, Sendable {
    case ipa(URL)
    case app(URL)

    public var url: URL {
        switch self {
        case let .ipa(url), let .app(url): return url
        }
    }
}

public enum InjectionTarget: Codable, Hashable, Sendable {
    case mainExecutable
    /// 解包后按 3 → 2 → `ProtobufLite` 选宿主，都没有才回落主程序。
    case preferredFrameworkHost
    /// 用户指定的 ProtobufLite 档（`ProtobufLite3` / `ProtobufLite2` / `ProtobufLite`），找不到就失败。
    case namedFrameworkHost(String)
    case relativeMachO(ValidatedRelativePath)
}

public enum InjectionLoadKind: String, Codable, Hashable, CaseIterable, Sendable {
    case required
    case weak

    public var loadCommandName: String {
        switch self {
        case .required: return "LC_LOAD_DYLIB"
        case .weak: return "LC_LOAD_WEAK_DYLIB"
        }
    }

    public var displayName: String {
        switch self {
        case .required: return L("plan.loadKind.required")
        case .weak: return L("plan.loadKind.weak")
        }
    }
}

public enum ExistingLoadCommandPolicy: String, Codable, Hashable, CaseIterable, Sendable {
    case fail
    case skip
    case replace
}

public struct InjectionItem: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var dylibURL: URL
    public var target: InjectionTarget
    public var loadKind: InjectionLoadKind
    public var customLoadPath: String?
    public var existingCommandPolicy: ExistingLoadCommandPolicy

    public init(
        id: UUID = UUID(),
        dylibURL: URL,
        target: InjectionTarget = .mainExecutable,
        loadKind: InjectionLoadKind = .required,
        customLoadPath: String? = nil,
        existingCommandPolicy: ExistingLoadCommandPolicy = .fail
    ) {
        self.id = id
        self.dylibURL = dylibURL
        self.target = target
        self.loadKind = loadKind
        self.customLoadPath = customLoadPath
        self.existingCommandPolicy = existingCommandPolicy
    }
}

public struct InjectionResource: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var sourceURL: URL
    public var destination: ValidatedRelativePath
    public var replaceExisting: Bool

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        destination: ValidatedRelativePath,
        replaceExisting: Bool = false
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.destination = destination
        self.replaceExisting = replaceExisting
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceURL, destination, replaceExisting
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        destination = try container.decode(ValidatedRelativePath.self, forKey: .destination)
        replaceExisting = try container.decodeIfPresent(Bool.self, forKey: .replaceExisting) ?? false
    }
}

public struct InjectionMetadataChanges: Codable, Hashable, Sendable {
    public var displayName: String?
    public var bundleID: String?
    public var shortVersion: String?
    public var buildVersion: String?
    public var minimumOSVersion: String?
    public var iconFiles: [URL]
    public var enableFileSharing: Bool
    public var repairWhiteIcon: Bool
    public var removeVOIPBackgroundMode: Bool
    public var removeURLSchemes: Bool
    /// 兼容旧预设。工作台已不再提供此开关，多开请直接改主 Bundle ID。
    public var randomizeBundleIDForPPQ: Bool
    public var ppqBundleSuffix: String?

    /// 工作台 / 向导未填写时写入的最低系统版本。
    public static let defaultMinimumOSVersion = "14.0"

    public init(
        displayName: String? = nil,
        bundleID: String? = nil,
        shortVersion: String? = nil,
        buildVersion: String? = nil,
        minimumOSVersion: String? = nil,
        iconFiles: [URL] = [],
        enableFileSharing: Bool = true,
        repairWhiteIcon: Bool = false,
        removeVOIPBackgroundMode: Bool = false,
        removeURLSchemes: Bool = false,
        randomizeBundleIDForPPQ: Bool = false,
        ppqBundleSuffix: String? = nil
    ) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.minimumOSVersion = minimumOSVersion
        self.iconFiles = iconFiles
        self.enableFileSharing = enableFileSharing
        self.repairWhiteIcon = repairWhiteIcon
        self.removeVOIPBackgroundMode = removeVOIPBackgroundMode
        self.removeURLSchemes = removeURLSchemes
        self.randomizeBundleIDForPPQ = randomizeBundleIDForPPQ
        self.ppqBundleSuffix = ppqBundleSuffix
    }

    enum CodingKeys: String, CodingKey {
        case displayName, bundleID, shortVersion, buildVersion, minimumOSVersion
        case iconFiles, enableFileSharing, repairWhiteIcon
        case removeVOIPBackgroundMode, removeURLSchemes
        case randomizeBundleIDForPPQ, ppqBundleSuffix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        shortVersion = try container.decodeIfPresent(String.self, forKey: .shortVersion)
        buildVersion = try container.decodeIfPresent(String.self, forKey: .buildVersion)
        minimumOSVersion = try container.decodeIfPresent(String.self, forKey: .minimumOSVersion)
        iconFiles = try container.decodeIfPresent([URL].self, forKey: .iconFiles) ?? []
        enableFileSharing = try container.decodeIfPresent(Bool.self, forKey: .enableFileSharing) ?? true
        repairWhiteIcon = try container.decodeIfPresent(Bool.self, forKey: .repairWhiteIcon) ?? false
        removeVOIPBackgroundMode = try container.decodeIfPresent(Bool.self, forKey: .removeVOIPBackgroundMode) ?? false
        removeURLSchemes = try container.decodeIfPresent(Bool.self, forKey: .removeURLSchemes) ?? false
        randomizeBundleIDForPPQ = try container.decodeIfPresent(Bool.self, forKey: .randomizeBundleIDForPPQ) ?? false
        ppqBundleSuffix = try container.decodeIfPresent(String.self, forKey: .ppqBundleSuffix)
    }

    public static func makePPQSuffix(length: Int = 6) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    /// 若打开 PPQ 随机化，把最终 Bundle ID 写进副本，保证改 plist 与重签用同一个值。
    public func resolvingBundleID(current: String, suffix: String? = nil) -> InjectionMetadataChanges {
        var next = self
        guard randomizeBundleIDForPPQ else { return next }
        let base = (bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? current
        let token = (suffix ?? ppqBundleSuffix).flatMap { $0.isEmpty ? nil : $0 } ?? Self.makePPQSuffix()
        next.ppqBundleSuffix = token
        if base.hasSuffix(".\(token)") {
            next.bundleID = base
        } else {
            next.bundleID = "\(base).\(token)"
        }
        return next
    }

    /// 未指定最低系统时落到 iOS 14，其它字段保持原样。
    public func resolvingWorkbenchDefaults() -> InjectionMetadataChanges {
        var next = self
        let current = next.minimumOSVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if current.isEmpty {
            next.minimumOSVersion = Self.defaultMinimumOSVersion
        }
        return next
    }
}

/// 只改 Info.plist 字典，不含拷图标 / 改嵌套 bundle。供单测与执行层共用。
public enum InfoPlistMetadataApplier {
    @discardableResult
    public static func apply(_ changes: InjectionMetadataChanges, to plist: inout [String: Any]) -> [String] {
        var log: [String] = []
        if let displayName = changes.displayName {
            plist["CFBundleDisplayName"] = displayName
            plist["CFBundleName"] = displayName
            log.append("displayName")
        }
        if let bundleID = changes.bundleID {
            plist["CFBundleIdentifier"] = bundleID
            log.append("bundleID")
        }
        if let shortVersion = changes.shortVersion, !shortVersion.isEmpty {
            plist["CFBundleShortVersionString"] = shortVersion
            log.append("shortVersion")
        }
        if let buildVersion = changes.buildVersion, !buildVersion.isEmpty {
            plist["CFBundleVersion"] = buildVersion
            log.append("buildVersion")
        }
        if let minimumOSVersion = changes.minimumOSVersion, !minimumOSVersion.isEmpty {
            plist["MinimumOSVersion"] = minimumOSVersion
            plist["LSMinimumSystemVersion"] = minimumOSVersion
            log.append("minimumOSVersion")
        }
        if changes.enableFileSharing {
            plist["UIFileSharingEnabled"] = true
            plist["LSSupportsOpeningDocumentsInPlace"] = true
            log.append("fileSharing")
        }
        if changes.removeVOIPBackgroundMode, let modes = plist["UIBackgroundModes"] as? [String] {
            let remaining = modes.filter { $0.caseInsensitiveCompare("voip") != .orderedSame }
            if remaining.isEmpty {
                plist.removeValue(forKey: "UIBackgroundModes")
            } else {
                plist["UIBackgroundModes"] = remaining
            }
            log.append("voip")
        }
        if changes.removeURLSchemes {
            plist.keys.filter { $0 == "CFBundleURLTypes" || $0.hasPrefix("CFBundleURLTypes~") }
                .forEach { plist.removeValue(forKey: $0) }
            log.append("urlSchemes")
        }
        return log
    }
}

/// injectipa `-f/--fixIcons` 的 plist 侧：去掉 `CFBundleIconName`，改用包内已有 PNG。
/// 真正修微信夜间主屏的是 `AssetCatalogIconRepair` 删 `Assets.car` 里那两对 rendition。
public enum AppIconRepair {
    public static func pngBasenames(in app: URL) -> [String] {
        let folder = IpaService.infoPlistURL(appBundle: app).deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var names: Set<String> = []
        for item in items {
            let ext = item.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg"].contains(ext) else { continue }
            let stem = item.deletingPathExtension().lastPathComponent
            let lower = stem.lowercased()
            guard lower.hasPrefix("appicon") || lower.hasPrefix("icon") else { continue }
            names.insert(iconBasename(stem))
        }
        return names.sorted()
    }

    public static func apply(to plist: inout [String: Any], extraFiles: [String] = []) {
        var names = plist["CFBundleIconFiles"] as? [String] ?? []
        plist.removeValue(forKey: "CFBundleIconName")
        for key in plist.keys where key == "CFBundleIcons" || key.hasPrefix("CFBundleIcons~") {
            guard var icons = plist[key] as? [String: Any] else { continue }
            var primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
            names += primary["CFBundleIconFiles"] as? [String] ?? []
            primary.removeValue(forKey: "CFBundleIconName")
            icons["CFBundlePrimaryIcon"] = primary
            plist[key] = icons
        }
        names += extraFiles
        let unique = Array(Set(names.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return }
        plist["CFBundleIconFiles"] = unique
        for key in plist.keys where key == "CFBundleIcons" || key.hasPrefix("CFBundleIcons~") {
            guard var icons = plist[key] as? [String: Any] else { continue }
            var primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
            primary["CFBundleIconFiles"] = unique
            primary.removeValue(forKey: "CFBundleIconName")
            icons["CFBundlePrimaryIcon"] = primary
            plist[key] = icons
        }
    }

    static func iconBasename(_ file: String) -> String {
        var name = file
        for token in ["@3x", "@2x", "@1x"] {
            name = name.replacingOccurrences(of: token, with: "")
        }
        return name
    }
}

public enum ComponentDisposition: String, Codable, Hashable, CaseIterable, Sendable {
    case preserve
    case remove
}

public struct InjectionComponentPolicy: Codable, Hashable, Sendable {
    public var watch: ComponentDisposition
    public var plugIns: ComponentDisposition
    public var appClips: ComponentDisposition
    public var destructiveRemovalConfirmed: Bool

    public init(
        watch: ComponentDisposition = .preserve,
        plugIns: ComponentDisposition = .preserve,
        appClips: ComponentDisposition = .preserve,
        destructiveRemovalConfirmed: Bool = false
    ) {
        self.watch = watch
        self.plugIns = plugIns
        self.appClips = appClips
        self.destructiveRemovalConfirmed = destructiveRemovalConfirmed
    }

    public var removesAnything: Bool {
        watch == .remove || plugIns == .remove || appClips == .remove
    }
}

public struct RealDeviceSigningRecipe: Codable, Hashable, Sendable {
    public var identityID: String
    public var identityName: String
    /// 手机 IPA 走 zsign 时只要其中一份描述文件；电脑 .app 仍可按 bundle 映射。
    public var profilesByBundleID: [String: URL]
    /// 工作台直接丢入的 p12。有文件时 zsign 用它，不必先导入钥匙串。
    public var p12URL: URL?
    public var p12Password: String?

    public init(
        identityID: String,
        identityName: String,
        profilesByBundleID: [String: URL],
        p12URL: URL? = nil,
        p12Password: String? = nil
    ) {
        self.identityID = identityID
        self.identityName = identityName
        self.profilesByBundleID = profilesByBundleID
        self.p12URL = p12URL
        self.p12Password = p12Password
    }
}

public enum InjectionSigningMode: Codable, Hashable, Sendable {
    case none
    case adHoc
    case ldid
    case realDevice(RealDeviceSigningRecipe)
    case appleID(AppleIDSigningRecipe)
}

public struct InjectionPlan: Codable, Hashable, Sendable {
    public var input: InjectionInput
    public var items: [InjectionItem]
    public var resources: [InjectionResource]
    public var metadata: InjectionMetadataChanges
    public var components: InjectionComponentPolicy
    public var signing: InjectionSigningMode
    public var customOutputName: String?
    public var stripCodeSignatureIfNeeded: Bool
    /// 开启后扫描整包，把越狱 Substrate 路径改到包内运行库，必要时拷内置 stub。
    public var rewriteJailbreakDependencies: Bool

    public init(
        input: InjectionInput,
        items: [InjectionItem],
        resources: [InjectionResource] = [],
        metadata: InjectionMetadataChanges = .init(),
        components: InjectionComponentPolicy = .init(),
        signing: InjectionSigningMode = .adHoc,
        customOutputName: String? = nil,
        stripCodeSignatureIfNeeded: Bool = true,
        rewriteJailbreakDependencies: Bool = true
    ) {
        self.input = input
        self.items = items
        self.resources = resources
        self.metadata = metadata
        self.components = components
        self.signing = signing
        self.customOutputName = customOutputName
        self.stripCodeSignatureIfNeeded = stripCodeSignatureIfNeeded
        self.rewriteJailbreakDependencies = rewriteJailbreakDependencies
    }

    public func validated() throws -> ValidatedInjectionPlan {
        var messages: [String] = []
        let inputExtension = input.url.pathExtension.lowercased()
        switch input {
        case .ipa where inputExtension != "ipa":
            messages.append(L("plan.validation.ipaExtension"))
        case .app where inputExtension != "app":
            messages.append(L("plan.validation.appExtension"))
        default:
            break
        }
        if items.isEmpty { messages.append(L("plan.validation.noItems")) }

        var itemKeys = Set<String>()
        for item in items {
            if item.dylibURL.pathExtension.lowercased() != "dylib" {
                messages.append(L("plan.validation.notDylib", item.dylibURL.lastPathComponent))
            }
            if let path = item.customLoadPath {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || path.contains("\0") {
                    messages.append(L("plan.validation.invalidLoadPath", item.dylibURL.lastPathComponent))
                }
            }
            let key = item.dylibURL.standardizedFileURL.path + "|" + String(describing: item.target)
            if !itemKeys.insert(key).inserted {
                messages.append(L("plan.validation.duplicateMapping", item.dylibURL.lastPathComponent))
            }
        }

        var destinations = Set<String>()
        for resource in resources {
            let key = resource.destination.rawValue.precomposedStringWithCanonicalMapping.lowercased()
            if !destinations.insert(key).inserted {
                messages.append(L("plan.validation.resourceConflict", resource.destination.rawValue))
            }
        }
        if components.removesAnything && !components.destructiveRemovalConfirmed {
            messages.append(L("plan.validation.destructiveUnconfirmed"))
        }
        if let name = customOutputName {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("\0") {
                messages.append(L("plan.validation.outputName"))
            }
        }
        if let displayName = metadata.displayName,
           displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(L("plan.validation.displayNameEmpty"))
        }
        if let bundleID = metadata.bundleID,
           bundleID.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) == nil {
            messages.append(L("plan.validation.bundleIDFormat"))
        }
        if !messages.isEmpty { throw InjectionPlanError.validation(messages) }
        return ValidatedInjectionPlan(plan: self)
    }

    enum CodingKeys: String, CodingKey {
        case input, items, resources, metadata, components, signing
        case customOutputName, stripCodeSignatureIfNeeded, rewriteJailbreakDependencies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(InjectionInput.self, forKey: .input)
        items = try container.decode([InjectionItem].self, forKey: .items)
        resources = try container.decodeIfPresent([InjectionResource].self, forKey: .resources) ?? []
        metadata = try container.decodeIfPresent(InjectionMetadataChanges.self, forKey: .metadata) ?? .init()
        components = try container.decodeIfPresent(InjectionComponentPolicy.self, forKey: .components) ?? .init()
        signing = try container.decodeIfPresent(InjectionSigningMode.self, forKey: .signing) ?? .adHoc
        customOutputName = try container.decodeIfPresent(String.self, forKey: .customOutputName)
        stripCodeSignatureIfNeeded = try container.decodeIfPresent(Bool.self, forKey: .stripCodeSignatureIfNeeded) ?? true
        rewriteJailbreakDependencies = try container.decodeIfPresent(Bool.self, forKey: .rewriteJailbreakDependencies) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(items, forKey: .items)
        try container.encode(resources, forKey: .resources)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(components, forKey: .components)
        try container.encode(signing, forKey: .signing)
        try container.encodeIfPresent(customOutputName, forKey: .customOutputName)
        try container.encode(stripCodeSignatureIfNeeded, forKey: .stripCodeSignatureIfNeeded)
        try container.encode(rewriteJailbreakDependencies, forKey: .rewriteJailbreakDependencies)
    }
}

/// 只有经过 `InjectionPlan.validated()` 才能构造，执行层仅接受此不可变值。
public struct ValidatedInjectionPlan: Codable, Hashable, Sendable {
    public let input: InjectionInput
    public let items: [InjectionItem]
    public let resources: [InjectionResource]
    public let metadata: InjectionMetadataChanges
    public let components: InjectionComponentPolicy
    public let signing: InjectionSigningMode
    public let customOutputName: String?
    public let stripCodeSignatureIfNeeded: Bool
    public let rewriteJailbreakDependencies: Bool

    fileprivate init(plan: InjectionPlan) {
        input = plan.input
        items = plan.items
        resources = plan.resources
        metadata = plan.metadata
        components = plan.components
        signing = plan.signing
        customOutputName = plan.customOutputName
        stripCodeSignatureIfNeeded = plan.stripCodeSignatureIfNeeded
        rewriteJailbreakDependencies = plan.rewriteJailbreakDependencies
    }

    enum CodingKeys: String, CodingKey {
        case input, items, resources, metadata, components, signing
        case customOutputName, stripCodeSignatureIfNeeded, rewriteJailbreakDependencies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try container.decode(InjectionInput.self, forKey: .input)
        items = try container.decode([InjectionItem].self, forKey: .items)
        resources = try container.decodeIfPresent([InjectionResource].self, forKey: .resources) ?? []
        metadata = try container.decodeIfPresent(InjectionMetadataChanges.self, forKey: .metadata) ?? .init()
        components = try container.decodeIfPresent(InjectionComponentPolicy.self, forKey: .components) ?? .init()
        signing = try container.decodeIfPresent(InjectionSigningMode.self, forKey: .signing) ?? .adHoc
        customOutputName = try container.decodeIfPresent(String.self, forKey: .customOutputName)
        stripCodeSignatureIfNeeded = try container.decodeIfPresent(Bool.self, forKey: .stripCodeSignatureIfNeeded) ?? true
        rewriteJailbreakDependencies = try container.decodeIfPresent(Bool.self, forKey: .rewriteJailbreakDependencies) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(input, forKey: .input)
        try container.encode(items, forKey: .items)
        try container.encode(resources, forKey: .resources)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(components, forKey: .components)
        try container.encode(signing, forKey: .signing)
        try container.encodeIfPresent(customOutputName, forKey: .customOutputName)
        try container.encode(stripCodeSignatureIfNeeded, forKey: .stripCodeSignatureIfNeeded)
        try container.encode(rewriteJailbreakDependencies, forKey: .rewriteJailbreakDependencies)
    }
}

public enum InjectionPlanError: LocalizedError, Equatable {
    case invalidRelativePath(String)
    case validation([String])

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path):
            return L("plan.error.invalidRelativePath", path)
        case let .validation(messages):
            return L("plan.error.validation") + "\n" + messages.map { "• \($0)" }.joined(separator: "\n")
        }
    }
}

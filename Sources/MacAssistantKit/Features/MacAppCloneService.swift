import Foundation

public struct MacAppCloneOptions: Sendable {
    public var displayName: String
    public var bundleID: String
    public var signMethod: SignMethod
    public var prep: AppCloneBundlePrep
    public var relocateIfUnwritable: Bool

    public init(
        displayName: String,
        bundleID: String,
        signMethod: SignMethod = .codesignAdhoc,
        prep: AppCloneBundlePrep = .hardDefaults,
        relocateIfUnwritable: Bool = true
    ) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.signMethod = signMethod
        self.prep = prep
        self.relocateIfUnwritable = relocateIfUnwritable
    }
}

public enum MacAppCloneError: LocalizedError {
    case invalidApp
    case invalidDisplayName
    case invalidBundleID
    case outputExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidApp: return L("macapp.clone.error.invalidApp")
        case .invalidDisplayName: return L("macapp.clone.error.invalidDisplayName")
        case .invalidBundleID: return L("macapp.clone.error.invalidBundleID")
        case let .outputExists(path): return L("macapp.clone.error.outputExists", path)
        }
    }
}

public enum MacAppCloneService {
    public static func clone(
        appAt source: URL,
        options: MacAppCloneOptions,
        outputURL: URL? = nil
    ) throws -> URL {
        guard source.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(source) else {
            throw MacAppCloneError.invalidApp
        }
        let name = options.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
            throw MacAppCloneError.invalidDisplayName
        }
        let bundleID = options.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bundleID.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
            throw MacAppCloneError.invalidBundleID
        }
        _ = try IpaService.infoPlist(appBundle: source)

        let proposed: URL
        if let outputURL {
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw MacAppCloneError.outputExists(outputURL.path)
            }
            proposed = outputURL
        } else {
            let directory = options.relocateIfUnwritable
                ? AppCloneBundlePreparer.writableOutputDirectory(nextTo: source)
                : source.deletingLastPathComponent()
            proposed = AppCloneBundlePreparer.uniqueAppURL(named: name, in: directory)
        }
        try FileManager.default.createDirectory(
            at: proposed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = proposed.deletingLastPathComponent()
            .appendingPathComponent(".\(proposed.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        if options.prep.stripNestedBundles {
            AppCloneBundlePreparer.removeNestedBundles(in: temporary)
        }
        if options.prep.stripProvisioningProfile {
            AppCloneBundlePreparer.removeProvisioningProfile(in: temporary)
        }

        try SigningService.rewriteBundleIDGraph(in: temporary, rootBundleID: bundleID)
        try updateRootInfoPlist(
            in: temporary,
            values: [
                "CFBundleDisplayName": name,
                "CFBundleName": name,
                "CFBundleIdentifier": bundleID
            ]
        )
        if options.prep.stripLocalizedNames {
            AppCloneBundlePreparer.stripLocalizedDisplayNames(in: temporary)
        }
        var log: [String] = []
        _ = try SigningService.resignJailbreak(
            app: temporary,
            method: options.signMethod,
            entitlements: nil,
            log: &log
        )
        try FileManager.default.moveItem(at: temporary, to: proposed)
        if options.prep.tintFinderIcon {
            AppCloneBundlePreparer.tintFinderIcon(at: proposed, index: options.prep.iconIndex)
        }
        return proposed
    }

    private static func updateRootInfoPlist(in app: URL, values: [String: String]) throws {
        let plistURL = IpaService.infoPlistURL(appBundle: app)
        let data = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw MacAppCloneError.invalidApp
        }
        values.forEach { plist[$0.key] = $0.value }
        plist["LSHasLocalizedDisplayName"] = nil
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        ).write(to: plistURL, options: .atomic)
    }
}

import Foundation

public enum AppCloneService {
    private static let lock = NSLock()
    private static let helperLock = NSLock()
    private static let launcherName = "MacAssistantCloneLauncher"
    private static let envDylibName = "libMacAssistantCloneEnv.dylib"
    private static let envInstallName = "@executable_path/../Frameworks/libMacAssistantCloneEnv.dylib"
    private static let clonePlistName = "MacAssistantClone.plist"
    /// Bump when CloneSupport sources change so the on-disk helper cache is rebuilt.
    private static let helperGeneration = "2"

    public static var hasBundledCloneHelpers: Bool {
        bundledHelper(launcherName) != nil && bundledHelper(envDylibName) != nil
    }

    public static func suggestedName(for appName: String, existing: [String]) -> String {
        nextIndexedName(base: sanitizedFileName(appName), taken: existing)
    }

    public static func suggestedBundleID(for bundleID: String, existing: [String]) -> String {
        let root = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = Set(existing.map { $0.lowercased() })
        let first = "\(root).clone"
        if !taken.contains(first.lowercased()) { return first }
        var index = 2
        while taken.contains("\(root).clone\(index)".lowercased()) {
            index += 1
        }
        return "\(root).clone\(index)"
    }

    public static func nextIndexedName(base: String, taken: [String]) -> String {
        let existing = Set(taken.map { $0.lowercased() })
        var index = 2
        while existing.contains("\(base)\(index)".lowercased()) {
            index += 1
        }
        return "\(base)\(index)"
    }

    public static func isValidCloneName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.contains("/")
            && !trimmed.contains("\\")
            && !trimmed.contains(":")
            && trimmed != "."
            && trimmed != ".."
    }

    public static func isValidBundleID(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]+$"#, options: .regularExpression) != nil
    }

    public static func isValidProxy(_ proxy: AppCloneProxy) -> Bool {
        let host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty && (1...65_535).contains(proxy.port)
    }

    public static func filteredEntitlements(_ entitlements: [String: Any]) -> [String: Any] {
        let blockedPrefixes = [
            "com.apple.security.app-sandbox",
            "com.apple.security.application-groups",
            "com.apple.developer.",
            "com.apple.application-identifier",
            "keychain-access-groups",
        ]
        return entitlements.filter { key, _ in
            !blockedPrefixes.contains { key == $0 || key.hasPrefix($0) }
        }
    }

    public static func substitute(_ value: String, dataDirectory: URL) -> String {
        value.replacingOccurrences(of: AppCloneToken.dataDirectory, with: dataDirectory.path)
    }

    public static func list(paths: AppClonePaths = .default) -> [AppCloneRecord] {
        loadRegistry(paths: paths)
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public static func clone(_ request: AppCloneRequest, paths: AppClonePaths = .default) throws -> AppCloneRecord {
        var request = request
        request.cloneName = request.cloneName.trimmingCharacters(in: .whitespacesAndNewlines)
        request.displayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        request.bundleID = request.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.displayName.isEmpty { request.displayName = request.cloneName }
        if var proxy = request.proxy {
            proxy.host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
            request.proxy = proxy
        }
        try validate(request)
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.apps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)

        let probe = try AppCloneProber.probe(request.source)
        let strategy = request.strategy ?? probe.recipe.strategy
        let outputDirectory = request.outputDirectory ?? paths.apps
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destination = outputDirectory
            .appendingPathComponent(request.cloneName)
            .appendingPathExtension("app")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AppCloneError.outputExists(destination.path)
        }
        let dataDirectory = request.dataDirectory
            ?? paths.data.appendingPathComponent(request.cloneName, isDirectory: true)
        let recipe = resolvedRecipe(probe.recipe, request: request, strategy: strategy)
        let environment = resolvedEnvironment(recipe: recipe, dataDirectory: dataDirectory, proxy: request.proxy)
        let arguments = recipe.launchArguments.map { substitute($0, dataDirectory: dataDirectory) }
        try prepareData(recipe: recipe, environment: environment, dataDirectory: dataDirectory, bundleIDs: [probe.info.bundleID, request.bundleID])

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }

        let usedInjection: AppCloneInjection
        switch strategy {
        case .soft:
            usedInjection = try buildSoftClone(
                probe: probe,
                destination: staging,
                environment: environment,
                arguments: arguments,
                paths: paths
            )
        case .hard:
            usedInjection = try buildHardClone(
                probe: probe,
                destination: staging,
                recipe: recipe,
                environment: environment,
                arguments: arguments,
                preferredInjection: request.injection,
                paths: paths
            )
        }

        if strategy == .hard {
            if request.bundlePrep.stripNestedBundles {
                AppCloneBundlePreparer.removeNestedBundles(in: staging)
            }
            if request.bundlePrep.stripProvisioningProfile {
                AppCloneBundlePreparer.removeProvisioningProfile(in: staging)
            }
        }
        try applyIdentity(
            in: staging,
            displayName: request.displayName,
            bundleID: request.bundleID,
            stripURLSchemes: recipe.stripURLSchemes,
            stripLocalizedNames: request.bundlePrep.stripLocalizedNames
        )
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", staging.path])
        try resign(staging, source: request.source, stripSandbox: recipe.stripSandbox)
        try FileManager.default.moveItem(at: staging, to: destination)
        register(destination)
        if request.bundlePrep.tintFinderIcon {
            AppCloneBundlePreparer.tintFinderIcon(at: destination, index: request.bundlePrep.iconIndex)
        }

        let record = AppCloneRecord(
            name: request.cloneName,
            displayName: request.displayName,
            sourcePath: request.source.standardizedFileURL.path,
            sourceBundleID: probe.info.bundleID,
            clonePath: destination.standardizedFileURL.path,
            dataPath: dataDirectory.standardizedFileURL.path,
            bundleID: request.bundleID,
            strategy: strategy,
            kind: recipe.kind,
            injection: usedInjection,
            recipeName: probe.matchedBuiltin ? probe.recipe.appName : L("appclone.recipe.auto"),
            proxy: request.proxy
        )
        do {
            try save(record, paths: paths)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return record
    }

    @discardableResult
    public static func update(id: UUID, paths: AppClonePaths = .default) throws -> AppCloneRecord {
        guard var record = loadRegistry(paths: paths).first(where: { $0.id == id }) else {
            throw AppCloneError.cloneMissing
        }
        let source = record.sourceURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AppCloneError.sourceMissing
        }
        let aside = record.cloneExists
            ? record.cloneURL.deletingLastPathComponent()
                .appendingPathComponent(".\(record.cloneURL.lastPathComponent).updating-\(UUID().uuidString)")
            : nil
        if let aside {
            try FileManager.default.moveItem(at: record.cloneURL, to: aside)
        }
        do {
            let request = AppCloneRequest(
                source: source,
                cloneName: record.name,
                displayName: record.displayName,
                bundleID: record.bundleID,
                strategy: record.strategy,
                injection: record.injection == .auto ? .auto : record.injection,
                proxy: record.proxy,
                outputDirectory: record.cloneURL.deletingLastPathComponent(),
                dataDirectory: record.dataURL
            )
            let created = try clone(request, paths: paths)
            if let aside {
                try? FileManager.default.removeItem(at: aside)
            }
            record.clonePath = created.clonePath
            record.injection = created.injection
            record.updatedAt = Date()
            record.kind = created.kind
            try replace(record, paths: paths)
            try removeDuplicate(named: created.name, keeping: record.id, paths: paths)
            return record
        } catch {
            if let aside,
               FileManager.default.fileExists(atPath: aside.path),
               !FileManager.default.fileExists(atPath: record.clonePath) {
                try? FileManager.default.moveItem(at: aside, to: record.cloneURL)
            }
            throw error
        }
    }

    public static func remove(id: UUID, deleteData: Bool, paths: AppClonePaths = .default) throws {
        guard let record = loadRegistry(paths: paths).first(where: { $0.id == id }) else {
            throw AppCloneError.cloneMissing
        }
        if record.cloneExists {
            try FileManager.default.removeItem(at: record.cloneURL)
        }
        if deleteData, FileManager.default.fileExists(atPath: record.dataPath) {
            try FileManager.default.removeItem(at: record.dataURL)
        }
        lock.lock()
        defer { lock.unlock() }
        let items = loadRegistryUnlocked(paths: paths).filter { $0.id != id }
        try writeRegistry(items, paths: paths)
    }

    public static func installedApps() -> [URL] {
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var apps: [URL] = []
        for directory in directories {
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension.lowercased() == "app" {
                if FileSystemHelper.isDirectory(url) {
                    apps.append(url)
                }
            }
        }
        apps.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return apps
    }

    // MARK: - Validation / recipe

    private static func validate(_ request: AppCloneRequest) throws {
        guard isValidCloneName(request.cloneName), isValidCloneName(request.displayName) else {
            throw AppCloneError.invalidName
        }
        guard isValidBundleID(request.bundleID) else {
            throw AppCloneError.invalidBundleID
        }
        if let proxy = request.proxy, !isValidProxy(proxy) {
            throw AppCloneError.invalidProxy
        }
    }

    private static func resolvedRecipe(
        _ recipe: AppCloneRecipe,
        request: AppCloneRequest,
        strategy: AppCloneStrategy
    ) -> AppCloneRecipe {
        var resolved = recipe
        resolved.strategy = strategy
        if strategy == .hard,
           resolved.launchArguments.allSatisfy({ !$0.contains(AppCloneToken.dataDirectory) }),
           resolved.environment.values.allSatisfy({ !$0.contains(AppCloneToken.dataDirectory) }) {
            resolved.environment["HOME"] = "{{CLONE_DATA_DIR}}/Home"
            resolved.environment["TMPDIR"] = "{{CLONE_DATA_DIR}}/Tmp"
        }
        return resolved
    }

    public static func resolvedEnvironment(
        recipe: AppCloneRecipe,
        dataDirectory: URL,
        proxy: AppCloneProxy?
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for (key, value) in recipe.environment {
            environment[key] = substitute(value, dataDirectory: dataDirectory)
        }
        if let proxy {
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
                environment[key] = proxy.urlString
            }
            environment["NO_PROXY"] = proxy.noProxy
            environment["no_proxy"] = proxy.noProxy
        }
        return environment
    }

    // MARK: - Engines

    private static func buildSoftClone(
        probe: AppCloneProbe,
        destination: URL,
        environment: [String: String],
        arguments: [String],
        paths: AppClonePaths
    ) throws -> AppCloneInjection {
        let contents = destination.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let sourceResources = probe.info.url.appendingPathComponent("Contents/Resources", isDirectory: true)
        if FileSystemHelper.isDirectory(sourceResources) {
            try FileSystemHelper.cloneOrCopyItem(at: sourceResources, to: resources)
        } else {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(
            at: IpaService.infoPlistURL(appBundle: probe.info.url),
            to: contents.appendingPathComponent("Info.plist")
        )
        try writeClonePlist(
            in: destination,
            target: probe.info.executable.path,
            relative: false,
            environment: environment,
            arguments: arguments,
            insertLibraries: []
        )
        try installLauncher(named: probe.info.executable.lastPathComponent, in: macos, paths: paths)
        return .launcher
    }

    private static func buildHardClone(
        probe: AppCloneProbe,
        destination: URL,
        recipe: AppCloneRecipe,
        environment: [String: String],
        arguments: [String],
        preferredInjection: AppCloneInjection,
        paths: AppClonePaths
    ) throws -> AppCloneInjection {
        try FileSystemHelper.cloneOrCopyItem(at: probe.info.url, to: destination)
        makeTreeWritable(destination)
        pruneStaleFrameworks(in: destination)
        let executableName = probe.info.executable.lastPathComponent
        let executable = destination.appendingPathComponent("Contents/MacOS/\(executableName)")
        let frameworks = destination.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)

        let useDylib = shouldUseDylib(
            preferred: preferredInjection,
            kind: recipe.kind,
            hasLaunchArgs: !arguments.isEmpty,
            executable: executable
        )
        // 启动参数只能靠启动器拼进 argv；选了 dylib 但带参数时仍走启动器。
        if useDylib && arguments.isEmpty {
            try installEnvDylib(into: frameworks, paths: paths)
            do {
                _ = try DylibInjector.inject(
                    dylibPath: envInstallName,
                    intoFileAt: executable,
                    stripCodeSignature: true
                )
                try writeClonePlist(
                    in: destination,
                    target: executableName,
                    relative: true,
                    environment: environment,
                    arguments: arguments,
                    insertLibraries: []
                )
                return .dylib
            } catch {
                if preferredInjection == .dylib {
                    throw error
                }
            }
        }

        let backup = executable.deletingLastPathComponent().appendingPathComponent("\(executableName).bin")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: executable, to: backup)
        try installEnvDylib(into: frameworks, paths: paths)
        try writeClonePlist(
            in: destination,
            target: "\(executableName).bin",
            relative: true,
            environment: environment,
            arguments: arguments,
            insertLibraries: ["../Frameworks/\(envDylibName)"]
        )
        try installLauncher(named: executableName, in: executable.deletingLastPathComponent(), paths: paths)
        return .launcher
    }

    private static func shouldUseDylib(
        preferred: AppCloneInjection,
        kind: AppCloneKind,
        hasLaunchArgs: Bool,
        executable: URL
    ) -> Bool {
        switch preferred {
        case .launcher: return false
        case .dylib: return true
        case .auto:
            if kind == .chromium || kind == .electron || hasLaunchArgs { return false }
            return FileManager.default.isReadableFile(atPath: executable.path)
        }
    }

    // MARK: - Bundle identity / data

    private static func applyIdentity(
        in app: URL,
        displayName: String,
        bundleID: String,
        stripURLSchemes: Bool,
        stripLocalizedNames: Bool
    ) throws {
        try SigningService.rewriteBundleIDGraph(in: app, rootBundleID: bundleID)
        let values: [String: Any] = [
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName,
            "CFBundleIdentifier": bundleID,
        ]
        try updateRootInfoPlist(in: app) { plist in
            values.forEach { plist[$0.key] = $0.value }
            plist["LSHasLocalizedDisplayName"] = nil
            plist["TeamIdentifier"] = nil
            if stripURLSchemes {
                plist["CFBundleURLTypes"] = nil
            }
        }
        if stripLocalizedNames {
            AppCloneBundlePreparer.stripLocalizedDisplayNames(in: app)
        }
    }

    private static func prepareData(
        recipe: AppCloneRecipe,
        environment: [String: String],
        dataDirectory: URL,
        bundleIDs: [String]
    ) throws {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let home = URL(fileURLWithPath: environment["HOME"] ?? dataDirectory.appendingPathComponent("Home").path, isDirectory: true)
        let temporary = URL(fileURLWithPath: environment["TMPDIR"] ?? dataDirectory.appendingPathComponent("Tmp").path, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        seedPreferences(into: home, bundleIDs: bundleIDs)
        seedSpecialHomes(environment)
        linkWhitelist(recipe.symlinkWhitelist, into: home)
    }

    private static func seedPreferences(into home: URL, bundleIDs: [String]) {
        let fm = FileManager.default
        let realHome = fm.homeDirectoryForCurrentUser
        let prefs = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try? fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        copyIfMissing(
            realHome.appendingPathComponent("Library/Preferences/.GlobalPreferences.plist"),
            to: prefs.appendingPathComponent(".GlobalPreferences.plist")
        )
        copyIfMissing(
            realHome.appendingPathComponent(".CFUserTextEncoding"),
            to: home.appendingPathComponent(".CFUserTextEncoding")
        )
        let keychains = home.appendingPathComponent("Library/Keychains")
        let realKeychains = realHome.appendingPathComponent("Library/Keychains")
        if !fm.fileExists(atPath: keychains.path), fm.fileExists(atPath: realKeychains.path) {
            try? fm.createDirectory(at: home.appendingPathComponent("Library", isDirectory: true), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(at: keychains, withDestinationURL: realKeychains)
        }
        for bundleID in Set(bundleIDs) where !bundleID.isEmpty {
            let destination = prefs.appendingPathComponent("\(bundleID).plist")
            let candidates = [
                realHome.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
                realHome.appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist"),
            ]
            if let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                copyIfMissing(source, to: destination)
            }
        }
    }

    private static func seedSpecialHomes(_ environment: [String: String]) {
        let fm = FileManager.default
        let realHome = fm.homeDirectoryForCurrentUser
        if let dest = environment["CODEX_HOME"] {
            try? fm.createDirectory(at: URL(fileURLWithPath: dest, isDirectory: true), withIntermediateDirectories: true)
        }
        if let dest = environment["GEMINI_HOME"] ?? environment["ANTIGRAVITY_HOME"] ?? environment["GEMINI_CONFIG_DIR"] {
            let destination = URL(fileURLWithPath: dest, isDirectory: true)
            let source = realHome.appendingPathComponent(".gemini", isDirectory: true)
            if FileSystemHelper.isDirectory(source), !FileSystemHelper.isDirectory(destination) {
                try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: source, to: destination)
            }
        }
        if let dest = environment["CLAUDE_CONFIG_DIR"] {
            let destination = URL(fileURLWithPath: dest, isDirectory: true)
            let source = realHome.appendingPathComponent(".claude", isDirectory: true)
            if FileSystemHelper.isDirectory(source), !FileSystemHelper.isDirectory(destination) {
                try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: source, to: destination)
            }
            copyIfMissing(
                realHome.appendingPathComponent(".claude.json"),
                to: destination.appendingPathComponent(".claude.json")
            )
        }
    }

    private static func linkWhitelist(_ items: [String], into home: URL) {
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        for raw in items {
            let relative = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { continue }
            let destination = home.appendingPathComponent(relative)
            let source = realHome.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: destination.path)
            else { continue }
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        }
    }

    private static func copyIfMissing(_ source: URL, to destination: URL) {
        guard FileManager.default.fileExists(atPath: source.path),
              !FileManager.default.fileExists(atPath: destination.path)
        else { return }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private static func pruneStaleFrameworks(in app: URL) {
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard FileSystemHelper.isDirectory(frameworks) else { return }
        let bundles = FileSystemHelper.allFiles(in: frameworks) {
            $0.pathExtension.lowercased() == "framework" && FileSystemHelper.isDirectory($0)
        }
        for bundle in bundles {
            let versions = bundle.appendingPathComponent("Versions", isDirectory: true)
            let current = versions.appendingPathComponent("Current")
            guard FileSystemHelper.isDirectory(versions) else { continue }
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path))
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            let children = (try? FileManager.default.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                let name = child.lastPathComponent
                if name == "Current" { continue }
                if let destination, name == destination { continue }
                if FileSystemHelper.isDirectory(child) {
                    try? FileManager.default.removeItem(at: child)
                }
            }
        }
    }

    // MARK: - Signing / helpers

    private static func resign(_ app: URL, source: URL, stripSandbox: Bool) throws {
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", app.path])
        stripFinderJunk(in: app)
        do {
            let entitlementsFile: URL?
            if stripSandbox, let original = try? SigningService.signedEntitlements(at: source) {
                let filtered = filteredEntitlements(original)
                let file = try FileSystemHelper.makeTemporaryDirectory(prefix: "appclone-ent")
                    .appendingPathComponent("entitlements.plist")
                try writePlist(filtered, to: file)
                entitlementsFile = file
            } else {
                entitlementsFile = nil
            }
            try resignNestedCode(in: app, rootEntitlements: entitlementsFile)
            let result = try BinaryService.adhocSign(
                fileAt: app,
                entitlements: entitlementsFile,
                deep: true
            )
            try SigningService.requireSuccess(result, step: app.lastPathComponent)
            let verify = try ExternalTool.codesign.run(["--verify", "--deep", "--strict", app.path])
            try SigningService.requireSuccess(verify, step: L("signing.step.finalVerify"))
        } catch let error as AppCloneError {
            throw error
        } catch {
            throw AppCloneError.codesignFailed(error.localizedDescription)
        }
    }

    /// 嵌套组件失败不中断（与参考实现对齐：`2>/dev/null || true`），最后再 `--deep` 签主包。
    private static func resignNestedCode(in app: URL, rootEntitlements: URL?) throws {
        for item in cloneSigningOrder(app) where item != app {
            let ext = item.pathExtension.lowercased()
            let entitlementsURL: URL?
            if ext == "app" || ext == "appex",
               let nested = try? SigningService.signedEntitlements(at: item) {
                let nestedFile = (rootEntitlements ?? item)
                    .deletingLastPathComponent()
                    .appendingPathComponent("ent-\(UUID().uuidString).plist")
                try writePlist(filteredEntitlements(nested), to: nestedFile)
                entitlementsURL = nestedFile
            } else {
                entitlementsURL = nil
            }
            _ = try? BinaryService.adhocSign(
                fileAt: item,
                entitlements: entitlementsURL,
                deep: ext == "framework" || ext == "app" || ext == "appex"
            )
        }
    }

    private static func stripFinderJunk(in root: URL) {
        let names: Set<String> = [".DS_Store", ".localized"]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        var junk: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if names.contains(name) || name.hasPrefix("._") {
                junk.append(url)
            }
        }
        for url in junk {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `signingOrder` 只收集 bundle / dylib。硬分身会把原二进制改名为 `Foo.bin`，
    /// 必须单独签，否则 `--strict` 会报 Info.plist 与子组件签名不一致。
    private static func cloneSigningOrder(_ app: URL) -> [URL] {
        var order = SigningService.signingOrder(app: app)
        let extras = additionalMacOSExecutables(in: app).filter { candidate in
            !order.contains { $0.standardizedFileURL.path == candidate.standardizedFileURL.path }
        }
        if let appIndex = order.lastIndex(of: app) {
            order.insert(contentsOf: extras, at: appIndex)
        } else {
            order.append(contentsOf: extras)
        }
        return order
    }

    private static func additionalMacOSExecutables(in app: URL) -> [URL] {
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        guard FileSystemHelper.isDirectory(macos) else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: macos,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return items.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return false }
            return FileManager.default.isExecutableFile(atPath: url.path)
        }
    }

    private static func register(_ app: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try? Shell.run(lsregister, ["-f", app.path])
    }

    private static func writeClonePlist(
        in app: URL,
        target: String,
        relative: Bool,
        environment: [String: String],
        arguments: [String],
        insertLibraries: [String]
    ) throws {
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "TargetExecutable": target,
            "TargetIsRelative": relative,
            "Environment": environment,
            "Arguments": arguments,
            "InsertLibraries": insertLibraries,
        ]
        try writePlist(plist, to: resources.appendingPathComponent(clonePlistName))
    }

    private static func installLauncher(named name: String, in directory: URL, paths: AppClonePaths) throws {
        let source = try compiledLauncher(paths: paths)
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    private static func installEnvDylib(into frameworks: URL, paths: AppClonePaths) throws {
        let source = try compiledEnvDylib(paths: paths)
        let destination = frameworks.appendingPathComponent(envDylibName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func compiledLauncher(paths: AppClonePaths) throws -> URL {
        try compiledHelper(
            fileName: launcherName,
            sourceName: "clone_launcher",
            dynamic: false,
            paths: paths
        )
    }

    private static func compiledEnvDylib(paths: AppClonePaths) throws -> URL {
        try compiledHelper(
            fileName: envDylibName,
            sourceName: "clone_env",
            dynamic: true,
            paths: paths
        )
    }

    private static func compiledHelper(
        fileName: String,
        sourceName: String,
        dynamic: Bool,
        paths: AppClonePaths
    ) throws -> URL {
        if let bundled = bundledHelper(fileName) {
            return bundled
        }
        helperLock.lock()
        defer { helperLock.unlock() }
        let cache = paths.helpers.appendingPathComponent("g\(helperGeneration)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let output = cache.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: output.path) {
            return output
        }
        guard let source = Bundle.module.url(forResource: sourceName, withExtension: "m", subdirectory: "CloneSupport") else {
            throw AppCloneError.helperBuildFailed(L("appclone.error.missingSource", sourceName))
        }
        guard ExternalTool.clang.isAvailable else {
            throw AppCloneError.helperBuildFailed(L("appclone.error.needClang"))
        }
        var arguments = ["-O2", "-arch", HostArchitecture.processSlice, "-framework", "Foundation"]
        if dynamic {
            arguments += ["-dynamiclib", "-install_name", envInstallName]
        }
        arguments += ["-o", output.path, source.path]
        let result = try ExternalTool.clang.run(arguments)
        guard result.succeeded, FileManager.default.fileExists(atPath: output.path) else {
            throw AppCloneError.helperBuildFailed(result.combinedOutput)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: output.path)
        return output
    }

    private static func bundledHelper(_ name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Helpers"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Helpers")
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: helper.path) ? helper : nil
    }

    // MARK: - Registry

    private static func save(_ record: AppCloneRecord, paths: AppClonePaths) throws {
        lock.lock()
        defer { lock.unlock() }
        var items = loadRegistryUnlocked(paths: paths).filter { $0.id != record.id && $0.clonePath != record.clonePath }
        items.append(record)
        try writeRegistry(items, paths: paths)
    }

    private static func replace(_ record: AppCloneRecord, paths: AppClonePaths) throws {
        lock.lock()
        defer { lock.unlock() }
        var items = loadRegistryUnlocked(paths: paths)
        if let index = items.firstIndex(where: { $0.id == record.id }) {
            items[index] = record
        } else {
            items.append(record)
        }
        try writeRegistry(items, paths: paths)
    }

    private static func removeDuplicate(named name: String, keeping id: UUID, paths: AppClonePaths) throws {
        lock.lock()
        defer { lock.unlock() }
        let items = loadRegistryUnlocked(paths: paths).filter { $0.id == id || $0.name != name }
        try writeRegistry(items, paths: paths)
    }

    private static func loadRegistry(paths: AppClonePaths) -> [AppCloneRecord] {
        lock.lock()
        defer { lock.unlock() }
        return loadRegistryUnlocked(paths: paths)
    }

    private static func loadRegistryUnlocked(paths: AppClonePaths) -> [AppCloneRecord] {
        guard let data = try? Data(contentsOf: paths.registry) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RegistryFile.self, from: data))?.clones ?? []
    }

    private static func writeRegistry(_ items: [AppCloneRecord], paths: AppClonePaths) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(RegistryFile(clones: items))
        try data.write(to: paths.registry, options: .atomic)
    }

    private struct RegistryFile: Codable {
        var clones: [AppCloneRecord]
    }

    // MARK: - Plist helpers

    private static func updateRootInfoPlist(in app: URL, mutate: (inout [String: Any]) -> Void) throws {
        let url = IpaService.infoPlistURL(appBundle: app)
        var plist = try readPlist(url)
        mutate(&plist)
        try writePlist(plist, to: url)
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw AppCloneError.invalidApp
        }
        return plist
    }

    private static func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private static func sanitizedFileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "App" : cleaned
    }

    private static func makeTreeWritable(_ root: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }
}

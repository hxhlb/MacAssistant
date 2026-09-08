import Foundation

/// 访达会算进「系统数据」的用户目录。只展开主目录里的已知叶，不扫系统分区。
enum CleanupSystemData {
    static func expand(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        expandVirtualMachines(
            expandAndroidStudioCaches(
                expandAndroidSDK(
                    expandAndroidAVDs(
                        expandFirmware(
                            expandBackups(definitions, home: home),
                            home: home
                        ),
                        home: home
                    ),
                    home: home
                ),
                home: home
            ),
            home: home
        )
    }

    static func androidSDKRoot(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { continue }
            let candidate = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            guard isAcceptableHomePath(candidate, home: home) else { continue }
            return candidate
        }
        return home.appendingPathComponent("Library/Android/sdk", isDirectory: true)
    }

    static func expandBackups(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        replaceChildren(
            in: definitions,
            parentID: "ios-backups",
            home: home,
            include: { !$0.hasPrefix(".") }
        ) { directory, folder, parent in
            let info = backupInfo(at: directory)
            return CleanupTargetDefinition(
                id: "ios-backup:\(folder)",
                name: L("cleanup.ios-backup-item.name", info.name),
                detail: info.detail ?? L("cleanup.ios-backups.detail"),
                paths: [directory],
                risk: parent.risk,
                action: parent.action,
                defaultSelected: false,
                category: parent.category,
                systemImage: parent.systemImage,
                safetyDetails: parent.safetyDetails
            )
        }
    }

    static func expandFirmware(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        replaceChildren(
            in: definitions,
            parentID: "device-firmware",
            home: home,
            root: home.appendingPathComponent("Library/iTunes", isDirectory: true),
            include: { $0.hasSuffix("Software Updates") }
        ) { directory, folder, parent in
            CleanupTargetDefinition(
                id: "firmware:\(folder)",
                name: L("cleanup.device-firmware-item.name", folder),
                detail: L("cleanup.device-firmware.detail"),
                paths: [directory],
                risk: parent.risk,
                action: parent.action,
                defaultSelected: false,
                category: parent.category,
                systemImage: parent.systemImage,
                safetyDetails: parent.safetyDetails
            )
        }
    }

    static func expandAndroidAVDs(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        replaceChildren(
            in: definitions,
            parentID: "android-avd",
            home: home,
            include: { $0.hasSuffix(".avd") }
        ) { directory, folder, parent in
            let name = URL(fileURLWithPath: folder).deletingPathExtension().lastPathComponent
            var paths = [directory]
            let ini = directory.deletingLastPathComponent().appendingPathComponent("\(name).ini")
            if let file = CleanupDiscovery.realFile(ini),
               !CleanupDeniedPaths.contains(file, homeDirectory: home)
            {
                paths.append(file)
            }
            return CleanupTargetDefinition(
                id: "android-avd:\(folder)",
                name: L("cleanup.android-avd-item.name", name),
                detail: L("cleanup.android-avd.detail"),
                paths: paths,
                risk: parent.risk,
                action: parent.action,
                defaultSelected: false,
                category: parent.category,
                systemImage: parent.systemImage,
                safetyDetails: parent.safetyDetails
            )
        }
    }

    static func expandAndroidSDK(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        let sdk = androidSDKRoot(home: home)
        let remapped = remapAndroidSDKPaths(definitions, sdk: sdk)
        let images = replaceChildren(
            in: remapped,
            parentID: "android-sdk-images",
            home: home,
            include: { !$0.hasPrefix(".") }
        ) { directory, folder, parent in
            child(
                parent,
                id: "android-sdk:image:\(folder)",
                name: L("cleanup.android-sdk-image-item.name", folder),
                paths: [directory]
            )
        }
        let ndk = replaceChildren(
            in: images,
            parentID: "android-sdk-ndk",
            home: home,
            include: { !$0.hasPrefix(".") }
        ) { directory, folder, parent in
            child(
                parent,
                id: "android-sdk:ndk:\(folder)",
                name: L("cleanup.android-sdk-ndk-item.name", folder),
                paths: [directory]
            )
        }
        return replaceChildren(
            in: ndk,
            parentID: "android-sdk-platforms",
            home: home,
            include: { !$0.hasPrefix(".") }
        ) { directory, folder, parent in
            child(
                parent,
                id: "android-sdk:platform:\(folder)",
                name: L("cleanup.android-sdk-platform-item.name", folder),
                paths: [directory]
            )
        }
    }

    static func expandAndroidStudioCaches(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        replaceChildren(
            in: definitions,
            parentID: "android-studio-caches",
            home: home,
            root: home.appendingPathComponent("Library/Caches/Google", isDirectory: true),
            include: { $0.hasPrefix("AndroidStudio") },
            removeParentIfEmpty: true
        ) { directory, folder, parent in
            child(
                parent,
                id: "android-studio-cache:\(folder)",
                name: L("cleanup.android-studio-cache-item.name", folder),
                paths: [directory]
            )
        }
    }

    static func expandVirtualMachines(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        let specs: [(String, String?, String)] = [
            ("vm-utm", "utm", "cleanup.vm-utm-item.name"),
            ("vm-tart", nil, "cleanup.vm-tart-item.name"),
            ("vm-parallels", "pvm", "cleanup.vm-parallels-item.name"),
            ("vm-virtualbox", nil, "cleanup.vm-virtualbox-item.name"),
            ("vm-vmware", "vmwarevm", "cleanup.vm-vmware-item.name")
        ]
        return specs.reduce(definitions) { current, spec in
            replaceChildren(
                in: current,
                parentID: spec.0,
                home: home,
                include: { folder in
                    if let suffix = spec.1 {
                        return URL(fileURLWithPath: folder).pathExtension == suffix
                    }
                    return !folder.hasPrefix(".")
                },
                removeParentIfEmpty: true
            ) { directory, folder, parent in
                let name = URL(fileURLWithPath: folder).deletingPathExtension().lastPathComponent
                return child(
                    parent,
                    id: "vm:\(spec.0):\(folder)",
                    name: L(spec.2, name),
                    paths: [directory]
                )
            }
        }
    }

    static func backupInfo(at url: URL) -> (name: String, detail: String?) {
        let plist = url.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return (url.lastPathComponent, nil)
        }

        let name = (object["Device Name"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        var parts: [String] = []
        if let version = object["Product Version"] as? String, !version.isEmpty {
            parts.append(version)
        }
        if let date = object["Last Backup Date"] as? Date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.locale = Locale.current
            parts.append(formatter.string(from: date))
        }
        return (name, parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    static func isAcceptableHomePath(_ url: URL, home: URL) -> Bool {
        let candidate = url.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        guard candidate.path == homePath || candidate.path.hasPrefix(homePath + "/") else {
            return false
        }
        guard candidate.path != homePath else { return false }
        return !CleanupDeniedPaths.contains(candidate, homeDirectory: home)
    }

    private static func remapAndroidSDKPaths(
        _ definitions: [CleanupTargetDefinition],
        sdk: URL
    ) -> [CleanupTargetDefinition] {
        let map = [
            "android-sdk-images": sdk.appendingPathComponent("system-images", isDirectory: true),
            "android-sdk-ndk": sdk.appendingPathComponent("ndk", isDirectory: true),
            "android-sdk-platforms": sdk.appendingPathComponent("platforms", isDirectory: true)
        ]
        return definitions.map { definition in
            guard let root = map[definition.id] else { return definition }
            return CleanupTargetDefinition(
                id: definition.id,
                name: definition.name,
                detail: definition.detail,
                paths: [root],
                risk: definition.risk,
                action: definition.action,
                defaultSelected: definition.defaultSelected,
                category: definition.category,
                systemImage: definition.systemImage,
                safetyDetails: definition.safetyDetails
            )
        }
    }

    private static func child(
        _ parent: CleanupTargetDefinition,
        id: String,
        name: String,
        paths: [URL]
    ) -> CleanupTargetDefinition {
        CleanupTargetDefinition(
            id: id,
            name: name,
            detail: parent.detail,
            paths: paths,
            risk: parent.risk,
            action: parent.action,
            defaultSelected: false,
            category: parent.category,
            systemImage: parent.systemImage,
            safetyDetails: parent.safetyDetails
        )
    }

    private static func replaceChildren(
        in definitions: [CleanupTargetDefinition],
        parentID: String,
        home: URL,
        root: URL? = nil,
        include: (String) -> Bool,
        removeParentIfEmpty: Bool = false,
        makeItem: (URL, String, CleanupTargetDefinition) -> CleanupTargetDefinition
    ) -> [CleanupTargetDefinition] {
        guard let index = definitions.firstIndex(where: { $0.id == parentID }) else {
            return definitions
        }
        let parent = definitions[index]
        let scanRoot = root ?? parent.paths.first
        guard let scanRoot, let real = CleanupDiscovery.realDirectory(scanRoot) else {
            if removeParentIfEmpty {
                var result = definitions
                result.remove(at: index)
                return result
            }
            return definitions
        }

        let children = CleanupDiscovery.listChildren(of: real).compactMap { child -> CleanupTargetDefinition? in
            guard let directory = CleanupDiscovery.realDirectory(child) else { return nil }
            if CleanupDeniedPaths.contains(directory, homeDirectory: home) { return nil }
            let folder = directory.lastPathComponent
            guard include(folder) else { return nil }
            return makeItem(directory, folder, parent)
        }

        guard !children.isEmpty else {
            if removeParentIfEmpty {
                var result = definitions
                result.remove(at: index)
                return result
            }
            return definitions
        }
        var result = definitions
        result.remove(at: index)
        result.insert(contentsOf: children, at: index)
        return result
    }
}

import Foundation

/// 把 DerivedData 拆成按工程的可选项。读 info.plist 的 WorkspacePath，读不到就用目录名。
enum CleanupDerivedData {
    static func expand(
        _ definitions: [CleanupTargetDefinition],
        home: URL
    ) -> [CleanupTargetDefinition] {
        guard let index = definitions.firstIndex(where: { $0.id == "xcode-derived" }) else {
            return definitions
        }
        let parent = definitions[index]
        guard let root = parent.paths.first,
              let real = CleanupDiscovery.realDirectory(root)
        else {
            return definitions
        }

        let children = CleanupDiscovery.listChildren(of: real).compactMap { child -> CleanupTargetDefinition? in
            guard let directory = CleanupDiscovery.realDirectory(child) else { return nil }
            if CleanupDeniedPaths.contains(directory, homeDirectory: home) { return nil }
            let folder = directory.lastPathComponent
            if folder.hasPrefix(".") { return nil }
            let info = projectInfo(at: directory)
            return CleanupTargetDefinition(
                id: "xcode-derived:\(folder)",
                name: L("cleanup.xcode-derived-project.name", info.name),
                detail: info.workspace.map { L("cleanup.xcode-derived-project.detail", $0) }
                    ?? L("cleanup.xcode-derived.detail"),
                paths: [directory],
                risk: parent.risk,
                action: parent.action,
                defaultSelected: false,
                category: parent.category,
                systemImage: parent.systemImage,
                safetyDetails: parent.safetyDetails
            )
        }

        guard !children.isEmpty else { return definitions }
        var result = definitions
        result.remove(at: index)
        result.insert(contentsOf: children, at: index)
        return result
    }

    static func projectInfo(at url: URL) -> (name: String, workspace: String?) {
        let plist = url.appendingPathComponent("info.plist")
        if let data = try? Data(contentsOf: plist),
           let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let workspacePath = object["WorkspacePath"] as? String
        {
            let name = URL(fileURLWithPath: workspacePath)
                .deletingPathExtension()
                .lastPathComponent
            if !name.isEmpty {
                return (name, workspacePath)
            }
        }
        return (fallbackName(url.lastPathComponent), nil)
    }

    static func fallbackName(_ folder: String) -> String {
        if folder == "ModuleCache.noindex" {
            return L("cleanup.xcode-derived-modulecache.name")
        }
        let parts = folder.split(separator: "-")
        if parts.count >= 2 {
            return parts.dropLast().joined(separator: "-")
        }
        return folder
    }
}

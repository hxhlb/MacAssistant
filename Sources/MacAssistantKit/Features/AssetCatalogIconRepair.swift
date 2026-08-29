import AssetCatalogSupport
import Foundation

/// injectipa `-f`：从主包 `Assets.car` 删除 `AppIcon_1024_dark.png` / `AppIcon_1024_tinted.png`
/// 的每一条 key（同一名字通常有一对，scale 不同）。文件共享是另一项，不在这里开。
public enum AssetCatalogIconRepair {
    public static var targetRenditionNames: [String] {
        MAAssetCatalogIconRepair.targetRenditionNames()
    }

    public struct Removal: Equatable, Sendable {
        public var catalogFileName: String
        public var renditionName: String
    }

    public static func catalogURLs(in app: URL) -> [URL] {
        [
            app.appendingPathComponent("Assets.car"),
            app.appendingPathComponent("Contents/Resources/Assets.car")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func containsTargetRendition(in catalogData: Data) -> [String] {
        targetRenditionNames.filter { name in
            guard let needle = name.data(using: .utf8) else { return false }
            return catalogData.range(of: needle) != nil
        }
    }

    public static func repair(in app: URL) throws -> [Removal] {
        var removals: [Removal] = []
        for catalog in catalogURLs(in: app) {
            let names = try MAAssetCatalogIconRepair.removeTargetRenditionsInCatalog(
                atPath: catalog.path
            )
            removals += names.map {
                Removal(catalogFileName: catalog.lastPathComponent, renditionName: $0)
            }
        }
        return removals
    }
}

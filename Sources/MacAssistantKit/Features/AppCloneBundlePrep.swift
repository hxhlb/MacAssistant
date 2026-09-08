import AppKit
import Foundation

/// 物理分身与隔离分身共用的收尾：嵌套 Bundle、描述文件、本地化名、Finder 图标。
public struct AppCloneBundlePrep: Sendable, Equatable {
    public var stripNestedBundles: Bool
    public var stripProvisioningProfile: Bool
    public var stripLocalizedNames: Bool
    public var tintFinderIcon: Bool
    public var iconIndex: Int

    public init(
        stripNestedBundles: Bool = true,
        stripProvisioningProfile: Bool = true,
        stripLocalizedNames: Bool = true,
        tintFinderIcon: Bool = false,
        iconIndex: Int = 2
    ) {
        self.stripNestedBundles = stripNestedBundles
        self.stripProvisioningProfile = stripProvisioningProfile
        self.stripLocalizedNames = stripLocalizedNames
        self.tintFinderIcon = tintFinderIcon
        self.iconIndex = iconIndex
    }

    public static let none = AppCloneBundlePrep(
        stripNestedBundles: false,
        stripProvisioningProfile: false,
        stripLocalizedNames: false,
        tintFinderIcon: false,
        iconIndex: 2
    )

    /// 物理分身默认剥嵌套组件；图标染色由界面单独打开，避免 setIcon 写 xattr 后 codesign --strict 失败。
    public static let hardDefaults = AppCloneBundlePrep(
        stripNestedBundles: true,
        stripProvisioningProfile: true,
        stripLocalizedNames: true,
        tintFinderIcon: false
    )

    /// 隔离分身默认保留 PlugIns / XPC，避免微信等应用缺辅助进程。
    public static let isolatedDefaults = AppCloneBundlePrep(
        stripNestedBundles: false,
        tintFinderIcon: false
    )
}

public enum AppCloneBundlePreparer {
    public static let nestedRelativePaths = [
        "Contents/PlugIns",
        "Contents/Watch",
        "Contents/XPCServices"
    ]

    public static func apply(_ prep: AppCloneBundlePrep, to app: URL) {
        if prep.stripNestedBundles { removeNestedBundles(in: app) }
        if prep.stripProvisioningProfile { removeProvisioningProfile(in: app) }
        if prep.stripLocalizedNames { stripLocalizedDisplayNames(in: app) }
    }

    public static func removeNestedBundles(in app: URL) {
        for relative in nestedRelativePaths {
            let url = app.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func removeProvisioningProfile(in app: URL) {
        let candidates = [
            app.appendingPathComponent("Contents/embedded.mobileprovision"),
            app.appendingPathComponent("embedded.mobileprovision")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func stripLocalizedDisplayNames(in app: URL) {
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let roots = [resources, app.appendingPathComponent("Resources", isDirectory: true)]
        for root in roots where FileSystemHelper.isDirectory(root) {
            for file in FileSystemHelper.allFiles(in: root, where: { $0.lastPathComponent == "InfoPlist.strings" }) {
                guard var plist = (try? readStrings(file)) else { continue }
                plist["CFBundleDisplayName"] = nil
                plist["CFBundleName"] = nil
                plist["CFBundleGetInfoString"] = nil
                try? writeStrings(plist, to: file)
            }
        }
    }

    public static func tintFinderIcon(at app: URL, index: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { tintFinderIcon(at: app, index: index) }
            return
        }
        let colors: [NSColor] = [
            .systemRed, .systemPurple, .systemBlue, .systemTeal,
            .systemGreen, .systemOrange, .systemPink, .systemYellow
        ]
        let color = colors[abs(index - 1) % colors.count].withAlphaComponent(0.4)
        let original = NSWorkspace.shared.icon(forFile: app.path)
        let size = original.size.width > 1 ? original.size : NSSize(width: 128, height: 128)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        NSWorkspace.shared.setIcon(tinted, forFile: app.path)
    }

    /// `/Applications` 写不进去时落到用户 Applications，避免收集管理员密码。
    public static func writableOutputDirectory(nextTo source: URL) -> URL {
        let adjacent = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: adjacent.path) {
            return adjacent
        }
        let userApps = AppClonePaths.userApplications
        try? FileManager.default.createDirectory(at: userApps, withIntermediateDirectories: true)
        return userApps
    }

    public static func uniqueAppURL(named name: String, in directory: URL) -> URL {
        FileSystemHelper.uniqueOutputURL(
            basedOn: directory.appendingPathComponent(name).appendingPathExtension("app")
        )
    }

    private static func readStrings(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return plist
    }

    private static func writeStrings(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

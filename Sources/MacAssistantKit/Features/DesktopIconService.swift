#if canImport(AppKit)
import AppKit
#endif
import Darwin
import Foundation

/// 可以自定义图标的目标种类。
public enum DesktopIconKind: String, Codable, Sendable {
    case file
    case folder
    case application

    public var label: String {
        switch self {
        case .file: return L("desktopicon.kind.file")
        case .folder: return L("desktopicon.kind.folder")
        case .application: return L("desktopicon.kind.application")
        }
    }

    public var systemImage: String {
        switch self {
        case .file: return "doc"
        case .folder: return "folder"
        case .application: return "app"
        }
    }
}

public struct DesktopIconItem: Identifiable, Hashable, Sendable {
    public var id: String { url.standardizedFileURL.path }
    public let url: URL
    public let name: String
    public let kind: DesktopIconKind
    public let hasCustomIcon: Bool
    public let isWritable: Bool
    public let isBlocked: Bool

    public init(
        url: URL,
        name: String,
        kind: DesktopIconKind,
        hasCustomIcon: Bool,
        isWritable: Bool,
        isBlocked: Bool
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.hasCustomIcon = hasCustomIcon
        self.isWritable = isWritable
        self.isBlocked = isBlocked
    }

    public var canApplyInPlace: Bool { !isBlocked && isWritable }
}

public struct DesktopIconHistoryRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let path: String
    public let name: String
    public let kind: DesktopIconKind
    public let appliedAt: Date
    public let imageFileName: String?

    public init(
        id: UUID = UUID(),
        path: String,
        name: String,
        kind: DesktopIconKind,
        appliedAt: Date = Date(),
        imageFileName: String? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.kind = kind
        self.appliedAt = appliedAt
        self.imageFileName = imageFileName
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum DesktopIconError: LocalizedError, Equatable, Sendable {
    case missingTarget
    case missingImage
    case targetMissing
    case unsupportedImage(String)
    case imageUnreadable
    case imageTooSmall
    case protectedPath
    case notWritable
    case applyFailed
    case restoreFailed
    case aliasFailed
    case listingDenied
    case desktopMissing

    public var errorDescription: String? {
        switch self {
        case .missingTarget: return L("desktopicon.error.missingTarget")
        case .missingImage: return L("desktopicon.error.missingImage")
        case .targetMissing: return L("desktopicon.error.targetMissing")
        case .unsupportedImage(let name): return L("desktopicon.error.unsupportedImage", name)
        case .imageUnreadable: return L("desktopicon.error.imageUnreadable")
        case .imageTooSmall: return L("desktopicon.error.imageTooSmall")
        case .protectedPath: return L("desktopicon.error.protectedPath")
        case .notWritable: return L("desktopicon.error.notWritable")
        case .applyFailed: return L("desktopicon.error.applyFailed")
        case .restoreFailed: return L("desktopicon.error.restoreFailed")
        case .aliasFailed: return L("desktopicon.error.aliasFailed")
        case .listingDenied: return L("desktopicon.error.listingDenied")
        case .desktopMissing: return L("desktopicon.error.desktopMissing")
        }
    }
}

/// 自定义文件 / 文件夹 / 应用图标。写入走系统 `NSWorkspace.setIcon`，
/// 不改 Info.plist，也不碰 Assets.car。
public enum DesktopIconService {
    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "heif", "icns", "webp"
    ]
    public static let hardMinimumPixelSize = 16
    public static let recommendedPixelSize = 256
    public static let iconPixelSizes = [16, 32, 64, 128, 256, 512, 1024]

    private static let skippedNames: Set<String> = [".DS_Store", ".localized", "Icon\r"]

    // MARK: - 路径

    public static func desktopDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw DesktopIconError.desktopMissing
        }
        return url.standardizedFileURL
    }

    public static func applicationDirectories() -> [URL] {
        let homeApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeApps
        ].filter { FileSystemHelper.isDirectory($0) }
    }

    public static func isBlocked(_ url: URL) -> Bool {
        let requested = url.standardizedFileURL
        if matchesBlocked(requested) { return true }
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path != requested.path && matchesBlocked(resolved)
    }

    public static func validateTarget(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw DesktopIconError.protectedPath
        }
        let requested = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: requested.path) else {
            throw DesktopIconError.targetMissing
        }
        if isBlocked(requested) {
            throw DesktopIconError.protectedPath
        }
    }

    public static func validateWritableTarget(_ url: URL) throws {
        try validateTarget(url)
        guard FileManager.default.isWritableFile(atPath: url.standardizedFileURL.path) else {
            throw DesktopIconError.notWritable
        }
    }

    // MARK: - 分类与列举

    public static func classify(_ url: URL) -> DesktopIconKind {
        classify(url, resolved: false)
    }

    public static func inspect(_ url: URL) -> DesktopIconItem {
        let requested = url.standardizedFileURL
        let values = try? requested.resourceValues(forKeys: [
            .localizedNameKey, .isWritableKey
        ])
        return DesktopIconItem(
            url: requested,
            name: values?.localizedName ?? requested.lastPathComponent,
            kind: classify(requested),
            hasCustomIcon: hasCustomIcon(at: requested),
            isWritable: values?.isWritable ?? FileManager.default.isWritableFile(atPath: requested.path),
            isBlocked: isBlocked(requested)
        )
    }

    public static func listItems(in directory: URL) throws -> [DesktopIconItem] {
        let root = directory.standardizedFileURL
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isApplicationKey, .isPackageKey,
                    .isAliasFileKey, .isSymbolicLinkKey, .isHiddenKey,
                    .localizedNameKey, .isWritableKey
                ],
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            if FileSystemHelper.isAccessPermissionError(error) {
                throw DesktopIconError.listingDenied
            }
            throw error
        }

        return urls.compactMap { item in
            let name = item.lastPathComponent
            if skippedNames.contains(name) || name.hasPrefix(".") { return nil }
            let values = try? item.resourceValues(forKeys: [.isHiddenKey])
            if values?.isHidden == true { return nil }
            return inspect(item)
        }
        .sorted(by: Self.compareItems)
    }

    public static func listDesktopItems() throws -> [DesktopIconItem] {
        try listItems(in: desktopDirectory())
    }

    public static func listApplications() -> [DesktopIconItem] {
        applicationDirectories().flatMap { directory in
            (try? listItems(in: directory))?.filter { $0.kind == .application } ?? []
        }
        .reduce(into: [String: DesktopIconItem]()) { partial, item in
            partial[item.id] = item
        }
        .values
        .sorted(by: Self.compareItems)
    }

    // MARK: - 图片文件

    public static func isSupportedIconImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        guard supportedExtensions.contains(ext) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return true
    }

    public static func validateImageFile(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && !supportedExtensions.contains(ext) {
            throw DesktopIconError.unsupportedImage(url.lastPathComponent)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw DesktopIconError.imageUnreadable
        }
        guard let header = try? readHeader(url, count: 16), isKnownImageHeader(header) else {
            throw DesktopIconError.imageUnreadable
        }
    }

    public static func isKnownImageHeader(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = [UInt8](data)
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        if bytes.starts(with: [0x42, 0x4D]) { return true }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return true
        }
        if data.count >= 4, String(data: data.prefix(4), encoding: .ascii) == "icns" { return true }
        if data.count >= 12,
           String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
           String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WEBP" {
            return true
        }
        if data.count >= 12, String(data: data.subdata(in: 4..<8), encoding: .ascii) == "ftyp" {
            return true
        }
        return false
    }

    public static func pixelSize(ofImageAt url: URL) -> CGSize? {
        #if canImport(AppKit)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return pixelSize(of: image)
        #else
        return nil
        #endif
    }

    // MARK: - 自定义图标标记

    public static func hasCustomIcon(at url: URL) -> Bool {
        var attributes = attrlist(
            bitmapcount: u_short(ATTR_BIT_MAP_COUNT),
            reserved: 0,
            commonattr: attrgroup_t(ATTR_CMN_FNDRINFO),
            volattr: 0,
            dirattr: 0,
            fileattr: 0,
            forkattr: 0
        )
        var buffer = [UInt8](repeating: 0, count: 4 + 32)
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return url.path.withCString { path in
                getattrlist(path, &attributes, base, raw.count, 0)
            }
        }
        guard status == 0 else { return false }
        let flags = UInt16(buffer[12]) << 8 | UInt16(buffer[13])
        return (flags & UInt16(0x0400)) != 0
    }

    // MARK: - AppKit 操作

    #if canImport(AppKit)
    public static func pixelSize(of image: NSImage) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for representation in image.representations {
            width = max(width, CGFloat(representation.pixelsWide))
            height = max(height, CGFloat(representation.pixelsHigh))
        }
        if width > 0, height > 0 { return CGSize(width: width, height: height) }
        return image.size
    }

    public static func loadIconImage(from url: URL) throws -> NSImage {
        try validateImageFile(url)
        guard let image = NSImage(contentsOf: url), image.isValid else {
            throw DesktopIconError.imageUnreadable
        }
        let size = pixelSize(of: image)
        if max(size.width, size.height) < CGFloat(hardMinimumPixelSize) {
            throw DesktopIconError.imageTooSmall
        }
        return image
    }

    public static func iconArtwork(from url: URL) throws -> NSImage {
        if isSupportedIconImage(url) {
            return try loadIconImage(from: url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesktopIconError.targetMissing
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard image.isValid, image.size.width > 0 else {
            throw DesktopIconError.imageUnreadable
        }
        return image
    }

    public static func imageFromPasteboard() -> NSImage? {
        NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
    }

    public static func currentIcon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    public static func prepareIconImage(_ image: NSImage) -> NSImage {
        let canvas = 1024
        let fitted = fittedRect(imageSize: pixelSize(of: image), in: CGFloat(canvas))
        let prepared = NSImage(size: NSSize(width: canvas, height: canvas))
        for size in iconPixelSizes {
            guard let representation = rasterize(image, canvas: canvas, fitted: fitted, output: size) else {
                continue
            }
            prepared.addRepresentation(representation)
        }
        if prepared.representations.isEmpty {
            return image
        }
        return prepared
    }

    public static func applyIcon(_ image: NSImage, to url: URL) throws {
        try validateWritableTarget(url)
        let prepared = prepareIconImage(image)
        let path = url.standardizedFileURL.path
        let applied = runOnMain {
            NSWorkspace.shared.setIcon(prepared, forFile: path, options: [])
        }
        guard applied else { throw DesktopIconError.applyFailed }
        refreshPresentation(for: url)
    }

    public static func restoreDefaultIcon(at url: URL) throws {
        try validateWritableTarget(url)
        let path = url.standardizedFileURL.path
        let restored = runOnMain {
            NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        }
        guard restored else { throw DesktopIconError.restoreFailed }
        refreshPresentation(for: url)
    }

    public static func createDesktopAlias(to target: URL) throws -> URL {
        try validateTarget(target)
        let desktop = try desktopDirectory()
        guard FileManager.default.isWritableFile(atPath: desktop.path) else {
            throw DesktopIconError.notWritable
        }
        let kind = classify(target)
        let baseName = kind == .application
            ? target.deletingPathExtension().lastPathComponent
            : target.lastPathComponent
        let proposed = desktop.appendingPathComponent(baseName)
        let aliasURL = FileSystemHelper.uniqueOutputURL(basedOn: proposed)
        do {
            let bookmark = try target.bookmarkData(
                options: [.suitableForBookmarkFile],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try URL.writeBookmarkData(bookmark, to: aliasURL)
        } catch {
            throw DesktopIconError.aliasFailed
        }
        return aliasURL
    }

    public static func refreshPresentation(for url: URL) {
        let path = url.standardizedFileURL.path
        runOnMain {
            NSWorkspace.shared.noteFileSystemChanged(path)
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: path
        )
    }

    public static func refreshDock() {
        runOnMain {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.apple.dock" }?
                .terminate()
        }
    }

    public static func reveal(_ url: URL) {
        runOnMain {
            NSWorkspace.shared.activateFileViewerSelecting([url.standardizedFileURL])
        }
    }
    #endif

    // MARK: - 历史

    public static func loadHistory(storeDirectory: URL? = nil) -> [DesktopIconHistoryRecord] {
        let file = historyFile(in: storeDirectory)
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([DesktopIconHistoryRecord].self, from: data)) ?? []
    }

    @discardableResult
    public static func recordHistory(
        item: DesktopIconItem,
        id: UUID = UUID(),
        imageFileName: String? = nil,
        storeDirectory: URL? = nil
    ) throws -> DesktopIconHistoryRecord {
        var records = loadHistory(storeDirectory: storeDirectory)
        records.removeAll { $0.path == item.url.standardizedFileURL.path }
        let record = DesktopIconHistoryRecord(
            id: id,
            path: item.url.standardizedFileURL.path,
            name: item.name,
            kind: item.kind,
            imageFileName: imageFileName
        )
        records.insert(record, at: 0)
        if records.count > 40 {
            let discarded = records.suffix(from: 40)
            records = Array(records.prefix(40))
            for old in discarded {
                if let name = old.imageFileName {
                    try? FileManager.default.removeItem(at: imagesDirectory(in: storeDirectory).appendingPathComponent(name))
                }
            }
        }
        try writeHistory(records, storeDirectory: storeDirectory)
        return record
    }

    public static func removeHistory(id: UUID, storeDirectory: URL? = nil) throws {
        var records = loadHistory(storeDirectory: storeDirectory)
        if let index = records.firstIndex(where: { $0.id == id }) {
            if let name = records[index].imageFileName {
                try? FileManager.default.removeItem(at: imagesDirectory(in: storeDirectory).appendingPathComponent(name))
            }
            records.remove(at: index)
            try writeHistory(records, storeDirectory: storeDirectory)
        }
    }

    #if canImport(AppKit)
    public static func saveHistoryImage(_ image: NSImage, id: UUID, storeDirectory: URL? = nil) throws -> String {
        let directory = imagesDirectory(in: storeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(id.uuidString).png"
        let file = directory.appendingPathComponent(fileName)
        let prepared = prepareIconImage(image)
        guard let tiff = prepared.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let data = representation.representation(using: .png, properties: [:])
        else {
            throw DesktopIconError.imageUnreadable
        }
        try data.write(to: file, options: .atomic)
        return fileName
    }

    public static func historyImage(named fileName: String, storeDirectory: URL? = nil) -> NSImage? {
        let file = imagesDirectory(in: storeDirectory).appendingPathComponent(fileName)
        return NSImage(contentsOf: file)
    }
    #endif

    public static func defaultStoreDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac小助手/DesktopIcons", isDirectory: true)
    }

    // MARK: - 内部

    private static func classify(_ url: URL, resolved: Bool) -> DesktopIconKind {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .isApplicationKey, .isPackageKey,
            .isAliasFileKey, .isSymbolicLinkKey
        ])
        if !resolved, values?.isAliasFile == true || values?.isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath()
            if target.path != url.standardizedFileURL.path {
                return classify(target, resolved: true)
            }
        }
        if values?.isApplication == true || url.pathExtension.lowercased() == "app" {
            return .application
        }
        if values?.isDirectory == true, values?.isPackage != true {
            return .folder
        }
        return .file
    }

    private static func compareItems(_ lhs: DesktopIconItem, _ rhs: DesktopIconItem) -> Bool {
        let rank: (DesktopIconKind) -> Int = { kind in
            switch kind {
            case .folder: return 0
            case .application: return 1
            case .file: return 2
            }
        }
        if rank(lhs.kind) != rank(rhs.kind) {
            return rank(lhs.kind) < rank(rhs.kind)
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func matchesBlocked(_ url: URL) -> Bool {
        let path = url.path
        let exact: Set<String> = [
            "/", "/System", "/usr", "/bin", "/sbin", "/Library",
            "/Applications", "/Users", "/Volumes", "/opt", "/private"
        ]
        if exact.contains(path) { return true }

        let prefixes = [
            "/System/",
            "/usr/",
            "/bin/",
            "/sbin/",
            "/var/db/",
            "/var/root/",
            "/private/etc/",
            "/private/var/db/",
            "/private/var/root/",
            "/Library/Apple/",
            "/Library/Updates/",
            "/Library/Developer/"
        ]
        if prefixes.contains(where: { path.hasPrefix($0) }) {
            return true
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home { return true }
        for name in [".ssh", ".gnupg", "Library"] {
            let prefix = home + "/" + name
            if path == prefix || path.hasPrefix(prefix + "/") {
                return true
            }
        }
        return false
    }

    private static func readHeader(_ url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func historyFile(in storeDirectory: URL?) -> URL {
        resolvedStoreDirectory(storeDirectory).appendingPathComponent("history.json")
    }

    private static func imagesDirectory(in storeDirectory: URL?) -> URL {
        resolvedStoreDirectory(storeDirectory).appendingPathComponent("images", isDirectory: true)
    }

    private static func resolvedStoreDirectory(_ storeDirectory: URL?) -> URL {
        storeDirectory ?? defaultStoreDirectory()
    }

    private static func writeHistory(_ records: [DesktopIconHistoryRecord], storeDirectory: URL?) throws {
        let directory = resolvedStoreDirectory(storeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: historyFile(in: storeDirectory), options: .atomic)
    }

    #if canImport(AppKit)
    private static func fittedRect(imageSize: CGSize, in canvas: CGFloat) -> CGRect {
        let width = max(imageSize.width, 1)
        let height = max(imageSize.height, 1)
        let scale = min(canvas / width, canvas / height)
        let fittedWidth = width * scale
        let fittedHeight = height * scale
        return CGRect(
            x: (canvas - fittedWidth) / 2,
            y: (canvas - fittedHeight) / 2,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    private static func rasterize(
        _ image: NSImage,
        canvas: Int,
        fitted: CGRect,
        output: Int
    ) -> NSBitmapImageRep? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: output,
            pixelsHigh: output,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        representation.size = NSSize(width: output, height: output)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: output, height: output).fill()
        let scale = CGFloat(output) / CGFloat(canvas)
        let dest = CGRect(
            x: fitted.origin.x * scale,
            y: fitted.origin.y * scale,
            width: fitted.width * scale,
            height: fitted.height * scale
        )
        image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1)
        return representation
    }

    private static func runOnMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
    #endif
}

import Combine
import Darwin
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// 扫描本机 Applications 目录，并按显示名 / 文件名做搜索。
public enum MacAppLibrary {
    public static var defaultSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    public static func discover(in directories: [URL] = defaultSearchDirectories) -> [URL] {
        let found = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }.filter { $0.pathExtension.lowercased() == "app" && FileSystemHelper.isDirectory($0) }
        return Array(Set(found)).sorted { displayName(of: $0).localizedStandardCompare(displayName(of: $1)) == .orderedAscending }
    }

    public static func displayName(of app: URL) -> String {
        let key = app.standardizedFileURL.path
        if let cached = DisplayNameCache.name(for: key) { return cached }
        let name: String
        if let plist = try? IpaService.infoPlist(appBundle: app) {
            if let value = plist["CFBundleDisplayName"] as? String, !value.isEmpty {
                name = value
            } else if let value = plist["CFBundleName"] as? String, !value.isEmpty {
                name = value
            } else {
                name = app.deletingPathExtension().lastPathComponent
            }
        } else {
            name = app.deletingPathExtension().lastPathComponent
        }
        DisplayNameCache.store(name, for: key)
        return name
    }

    public static func invalidateCaches(for app: URL? = nil) {
        DisplayNameCache.invalidate(app?.standardizedFileURL.path)
    }

    public static func matches(_ app: URL, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return TextSearch.matches(displayName(of: app), needle: query)
            || TextSearch.matches(app.deletingPathExtension().lastPathComponent, needle: query)
            || TextSearch.matches(app.path, needle: query)
    }

    public static func filtered(_ apps: [URL], search: String) -> [URL] {
        apps.filter { matches($0, search: search) }
    }
}

/// 监听 Applications 目录变化，1 秒防抖后重扫。进程内共用一份列表，进页不再整表重扫。
@MainActor
public final class MacAppLibraryMonitor: ObservableObject {
    public static let shared = MacAppLibraryMonitor()

    @Published public private(set) var apps: [URL] = []
    @Published public var extras: [URL] = []
    @Published public var searchText = ""
    @Published public private(set) var isScanning = false

    private var monitors: [DispatchSourceFileSystemObject] = []
    private var refreshTask: Task<Void, Never>?
    private let directories: [URL]
    private let persistToProcessCache: Bool
    private var watchersStarted = false

    public var visibleApps: [URL] {
        let merged = Array(Set(apps + extras.filter { FileSystemHelper.isDirectory($0) }))
            .sorted {
                MacAppLibrary.displayName(of: $0)
                    .localizedStandardCompare(MacAppLibrary.displayName(of: $1)) == .orderedAscending
            }
        return MacAppLibrary.filtered(merged, search: searchText)
    }

    public init(directories: [URL] = MacAppLibrary.defaultSearchDirectories) {
        self.directories = directories
        persistToProcessCache = directories.map(\.path) == MacAppLibrary.defaultSearchDirectories.map(\.path)
        if persistToProcessCache, let cached = ProcessCache.apps, !cached.isEmpty {
            apps = cached
            extras = ProcessCache.extras
        }
    }

    deinit {
        monitors.forEach { $0.cancel() }
        refreshTask?.cancel()
    }

    public func addExtra(_ url: URL) {
        guard url.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(url) else { return }
        if !extras.contains(url) { extras.append(url) }
        if !apps.contains(url) { apps.append(url) }
        persist()
    }

    /// 有缓存就直接显示；只在第一次或手动刷新时扫盘。
    public func ensureLoaded() {
        startWatchersIfNeeded()
        if apps.isEmpty {
            reload()
        }
    }

    public func reload() {
        isScanning = true
        MacAppLibrary.invalidateCaches()
        let directories = self.directories
        Task.detached(priority: .userInitiated) { [weak self] in
            let discovered = MacAppLibrary.discover(in: directories)
            await self?.apply(discovered)
        }
    }

    public func startWatching() {
        ensureLoaded()
    }

    public func stopWatching() {
        monitors.forEach { $0.cancel() }
        monitors.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        watchersStarted = false
    }

    private func startWatchersIfNeeded() {
        guard !watchersStarted else { return }
        watchersStarted = true
        for directory in directories {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let monitor = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .attrib],
                queue: .main
            )
            monitor.setEventHandler { [weak self] in
                self?.scheduleReload()
            }
            monitor.setCancelHandler {
                close(descriptor)
            }
            monitor.resume()
            monitors.append(monitor)
        }
    }

    private func scheduleReload() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func apply(_ discovered: [URL]) {
        apps = discovered
        extras.removeAll { extra in
            discovered.contains(extra) || !FileSystemHelper.isDirectory(extra)
        }
        isScanning = false
        persist()
    }

    private func persist() {
        guard persistToProcessCache else { return }
        ProcessCache.apps = apps
        ProcessCache.extras = extras
    }
}

private enum ProcessCache {
    static var apps: [URL]?
    static var extras: [URL] = []
}

private enum DisplayNameCache {
    private static let lock = NSLock()
    private static var names: [String: String] = [:]

    static func name(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[key]
    }

    static func store(_ name: String, for key: String) {
        lock.lock()
        names[key] = name
        lock.unlock()
    }

    static func invalidate(_ key: String?) {
        lock.lock()
        if let key {
            names.removeValue(forKey: key)
        } else {
            names.removeAll()
        }
        lock.unlock()
    }
}

#if canImport(AppKit)
public enum MacAppIconCache {
    private static let lock = NSLock()
    private static var images: [String: NSImage] = [:]

    public static func image(for app: URL) -> NSImage {
        let key = app.path
        lock.lock()
        if let cached = images[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let image = NSWorkspace.shared.icon(forFile: key)
        image.size = NSSize(width: 64, height: 64)
        lock.lock()
        images[key] = image
        lock.unlock()
        return image
    }

    static func invalidate(_ key: String?) {
        lock.lock()
        if let key {
            images.removeValue(forKey: key)
        } else {
            images.removeAll()
        }
        lock.unlock()
    }
}
#endif

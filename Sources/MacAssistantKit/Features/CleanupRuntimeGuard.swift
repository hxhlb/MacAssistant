import Darwin
import Foundation

/// 执行前的失败关闭探测：相关进程在跑或状态未知则跳过，不当失败。
/// 测试可注入，避免依赖本机是否真的在跑 Xcode。
public struct CleanupRuntimeGuard: Sendable {
    /// 当前进程名 / bundle 名；`nil` 表示进程表读不清。
    public var runningProcessNames: @Sendable () -> Set<String>?
    /// 目标下 SQLite/WAL 是否被占用。`true` 占用，`false` 空闲，`nil` 未知。
    public var isSQLiteFamilyBusy: @Sendable (URL) -> Bool?

    public init(
        runningProcessNames: @escaping @Sendable () -> Set<String>?,
        isSQLiteFamilyBusy: @escaping @Sendable (URL) -> Bool?
    ) {
        self.runningProcessNames = runningProcessNames
        self.isSQLiteFamilyBusy = isSQLiteFamilyBusy
    }

    /// 默认：进程表可读、没有 SQLite 占用。用于只测路径逻辑的夹具。
    public static let idle = CleanupRuntimeGuard(
        runningProcessNames: { [] },
        isSQLiteFamilyBusy: { _ in false }
    )

    public static let live = CleanupRuntimeGuard(
        runningProcessNames: { CleanupProcessTable.runningNames() },
        isSQLiteFamilyBusy: { CleanupProcessTable.isSQLiteFamilyBusy(at: $0) }
    )

    /// 若该项此刻不该删，返回已本地化的跳过原因。
    public func skipReason(for definition: CleanupTargetDefinition) -> String? {
        let watched = Self.watchedProcessNames(for: definition)
        guard !watched.isEmpty else { return nil }
        guard let running = runningProcessNames() else {
            return L("cleanup.message.process-unknown")
        }
        let runningLower = Set(running.map { $0.lowercased() })
        if let hit = watched.first(where: { runningLower.contains($0.lowercased()) }) {
            return L("cleanup.message.process-running", hit)
        }
        return nil
    }

    public static func watchedProcessNames(for definition: CleanupTargetDefinition) -> [String] {
        if definition.id.hasPrefix("xcode-derived")
            || ["xcode-caches", "xcode-devicesupport", "xcode-xctestdevices",
                "xcode-previews", "xcode-swiftpm", "simulator-caches"].contains(definition.id) {
            return ["Xcode", "Simulator"]
        }
        switch definition.id {
        case "chrome":
            return ["Google Chrome"]
        case "firefox":
            return ["Firefox", "firefox"]
        case "safari":
            return ["Safari"]
        case "edge":
            return ["Microsoft Edge"]
        case "brave":
            return ["Brave Browser"]
        case "vscode":
            return ["Code", "Visual Studio Code"]
        case "cursor":
            return ["Cursor"]
        case "jetbrains":
            return ["idea", "pycharm", "webstorm", "goland", "clion", "phpstorm", "rubymine"]
        case "npm":
            return ["npm", "node"]
        case "yarn":
            return ["yarn", "node"]
        case "pnpm":
            return ["pnpm", "node"]
        case "bun":
            return ["bun"]
        case "deno":
            return ["deno"]
        case "pip", "uv":
            return ["pip", "pip3", "python", "python3", "uv"]
        case "cocoapods":
            return ["pod", "ruby"]
        case "carthage":
            return ["carthage"]
        case "gradle", "gradle-wrapper", "maven":
            return ["gradle", "java", "mvn"]
        case "go-build", "go-modules":
            return ["go"]
        case "cargo":
            return ["cargo"]
        case "playwright":
            return ["node"]
        case "flutter":
            return ["flutter", "dart"]
        default:
            if definition.id.hasPrefix("user-cache:")
                || definition.id.hasPrefix("container-cache:")
                || definition.id.hasPrefix("group-cache:") {
                return processHints(fromCacheName: definition.paths.first?.lastPathComponent ?? "")
            }
            return []
        }
    }

    private static func processHints(fromCacheName name: String) -> [String] {
        guard !name.isEmpty else { return [] }
        var names = [name]
        if let last = name.split(separator: ".").last, !last.isEmpty {
            names.append(String(last))
        }
        let lowered = name.lowercased()
        if lowered.contains("xcode") { names.append("Xcode") }
        if lowered.contains("safari") { names.append("Safari") }
        if lowered.contains("chrome") { names.append("Google Chrome") }
        if lowered.contains("firefox") { names.append("Firefox") }
        return names
    }
}

enum CleanupProcessTable {
    static func runningNames() -> Set<String>? {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(bytesNeeded) / MemoryLayout<pid_t>.stride + 8)
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard filled > 0 else { return nil }

        var names = Set<String>()
        let count = Int(filled) / MemoryLayout<pid_t>.stride
        for pid in pids.prefix(count) where pid > 0 {
            var buffer = [CChar](repeating: 0, count: 128)
            let length = proc_name(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            names.insert(String(cString: buffer))
        }
        return names
    }

    static func isSQLiteFamilyBusy(at url: URL) -> Bool? {
        guard let files = sqliteFamilyFiles(under: url, limit: 48) else { return nil }
        if files.isEmpty { return false }
        return lsofBusy(files)
    }

    private static func sqliteFamilyFiles(under url: URL, limit: Int) -> [URL]? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return isSQLiteFamily(url) ? [url] : []
        }

        var found: [URL] = []
        var sawError = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                sawError = true
                return true
            }
        ) else {
            return nil
        }
        for case let child as URL in enumerator {
            if found.count >= limit { break }
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == true, isSQLiteFamily(child) {
                found.append(child)
            }
        }
        if found.isEmpty && sawError { return nil }
        return found
    }

    private static func isSQLiteFamily(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".sqlite")
            || name.hasSuffix(".sqlite-wal")
            || name.hasSuffix(".sqlite-shm")
            || name.hasSuffix(".db")
            || name.hasSuffix(".wal")
    }

    /// lsof 失败或看不清视为未知（`nil`），不用 sudo。
    private static func lsofBusy(_ urls: [URL]) -> Bool? {
        let executable = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        guard !urls.isEmpty else { return false }

        let arguments = ["-nP", "-F", "p"] + urls.map(\.path)
        do {
            let result = try Shell.run(executable, arguments)
            if result.stdout.contains("p"), result.stdout.rangeOfCharacter(from: .decimalDigits) != nil {
                return true
            }
            // lsof 在没有占用者时通常以 1 退出且无 pid 行。
            if result.exitCode == 0 || result.exitCode == 1 {
                return false
            }
            return nil
        } catch {
            return nil
        }
    }
}

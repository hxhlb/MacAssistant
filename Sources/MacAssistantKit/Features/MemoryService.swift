import Foundation
import Darwin

public enum MemoryPressureLevel: String, Sendable {
    case healthy
    case warning
    case critical
    case unknown

    public var label: String {
        switch self {
        case .healthy: return L("memory.pressure.healthy")
        case .warning: return L("memory.pressure.warning")
        case .critical: return L("memory.pressure.critical")
        case .unknown: return L("memory.pressure.unknown")
        }
    }
}

public struct MemorySnapshot: Sendable {
    public let physical: UInt64
    public let used: UInt64
    public let cached: UInt64
    public let compressed: UInt64
    public let swapUsed: UInt64
    public let pressureFreePercent: Int?
    public let pressureLevel: MemoryPressureLevel
    public let capturedAt: Date

    public init(
        physical: UInt64,
        used: UInt64,
        cached: UInt64,
        compressed: UInt64,
        swapUsed: UInt64,
        pressureFreePercent: Int?,
        pressureLevel: MemoryPressureLevel,
        capturedAt: Date = Date()
    ) {
        self.physical = physical
        self.used = used
        self.cached = cached
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.pressureFreePercent = pressureFreePercent
        self.pressureLevel = pressureLevel
        self.capturedAt = capturedAt
    }

    /// 进度条用系统已用 / 物理内存，和活动监视器「内存已用」同一口径，不用 free%。
    public var usedFraction: Double {
        guard physical > 0 else { return 0 }
        return Double(used) / Double(physical)
    }

    public var usedPercent: Int {
        Int((usedFraction * 100).rounded())
    }
}

public struct ProcessMemoryInfo: Identifiable, Hashable, Sendable {
    public let pid: Int32
    public let userID: UInt32
    public let rssBytes: UInt64
    /// 活动监视器「内存」列（phys_footprint）。采集失败时为 0，界面回退到 RSS。
    public let footprintBytes: UInt64
    public let executablePath: String
    public let displayName: String

    public var id: Int32 { pid }
    public var name: String {
        ProcessDisplayNameResolver.executableName(executablePath)
    }
    /// 列表排序和占比使用的占用：优先 footprint，否则 RSS。
    public var memoryBytes: UInt64 {
        footprintBytes > 0 ? footprintBytes : rssBytes
    }
    public var applicationBundlePath: String? {
        ProcessApplicationResolver.applicationBundlePath(forExecutablePath: executablePath)
    }

    public init(
        pid: Int32,
        userID: UInt32,
        rssBytes: UInt64,
        executablePath: String,
        footprintBytes: UInt64 = 0,
        displayName: String? = nil
    ) {
        self.pid = pid
        self.userID = userID
        self.rssBytes = rssBytes
        self.footprintBytes = footprintBytes
        self.executablePath = executablePath
        let fallback = ProcessDisplayNameResolver.executableName(executablePath)
        if let displayName, !displayName.isEmpty {
            self.displayName = displayName
        } else {
            self.displayName = fallback
        }
    }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        if String(pid).contains(needle) { return true }
        if displayName.localizedCaseInsensitiveContains(needle) { return true }
        if name.localizedCaseInsensitiveContains(needle) { return true }
        if executablePath.localizedCaseInsensitiveContains(needle) { return true }
        if let bundle = applicationBundlePath, bundle.localizedCaseInsensitiveContains(needle) {
            return true
        }
        return false
    }
}

public enum ProcessDisplayNameResolver {
    public static func executableName(_ path: String) -> String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        return component.isEmpty ? path : component
    }

    /// 给短二进制名补上 App 名称，避免 IDA 只显示 `ida`、搜索「IDA Professional」找不到。
    public static func displayName(executablePath: String) -> String {
        let fallback = executableName(executablePath)
        let bundles = ProcessApplicationResolver.applicationBundlePaths(forExecutablePath: executablePath)
        guard let bundlePath = bundles.last else { return fallback }

        let folderName = appFolderName(bundlePath)
        if let plistName = infoPlistName(bundlePath), !plistName.isEmpty {
            if plistName.compare(fallback, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
               let folderName {
                return folderName
            }
            return plistName
        }
        return folderName ?? fallback
    }

    public static func appFolderName(_ bundlePath: String) -> String? {
        let last = URL(fileURLWithPath: bundlePath).lastPathComponent
        guard last.lowercased().hasSuffix(".app"), last.count > 4 else { return nil }
        return String(last.dropLast(4))
    }

    public static func infoPlistName(_ bundlePath: String) -> String? {
        let url = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: url) else { return nil }
        if let display = plist["CFBundleDisplayName"] as? String {
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let name = plist["CFBundleName"] as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

public enum ProcessApplicationResolver {
    /// 返回可执行路径所属的最外层 .app。嵌套 Helper.app 会自然映射到宿主 App。
    public static func applicationBundlePath(forExecutablePath path: String) -> String? {
        applicationBundlePaths(forExecutablePath: path).first
    }

    /// 从外到内返回路径中的所有 .app bundle，供 UI 判断嵌套 Helper 是否应使用宿主图标。
    public static func applicationBundlePaths(forExecutablePath path: String) -> [String] {
        guard path.hasPrefix("/") else { return [] }
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        var bundles: [String] = []

        for component in components.dropFirst() {
            candidate.appendPathComponent(component)
            if component.lowercased().hasSuffix(".app"), component.count > 4 {
                bundles.append(candidate.standardizedFileURL.path)
            }
        }
        return bundles
    }
}

public struct ProcessIconCacheKey: Hashable, Sendable {
    public let pid: Int32
    public let bundlePath: String?

    public init(pid: Int32, bundlePath: String?) {
        self.pid = pid
        self.bundlePath = bundlePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.bundlePath, rhs.bundlePath) {
        case let (.some(left), .some(right)):
            // 同一 App 的主进程与多个 Helper 共用一份图标。
            return left == right
        case (nil, nil):
            // 无法归属 App 时才按 PID 区分运行中的独立进程。
            return lhs.pid == rhs.pid
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        if let bundlePath {
            hasher.combine(0)
            hasher.combine(bundlePath)
        } else {
            hasher.combine(1)
            hasher.combine(pid)
        }
    }
}

public enum ProcessSignal: Equatable, Sendable {
    case terminate
    case kill

    var rawValue: Int32 {
        switch self {
        case .terminate: return SIGTERM
        case .kill: return SIGKILL
        }
    }
}

public enum MemoryMaintenanceKind: Sendable, Equatable {
    case developerFileCacheBenchmark
}

public struct MemoryMaintenanceOperation: Sendable, Equatable {
    public let kind: MemoryMaintenanceKind
    public let title: String
    public let explanation: String
}

public enum MemoryServiceError: LocalizedError {
    case commandFailed(String)
    case invalidPID
    case protectedProcess(String)
    case permissionDenied
    case processNotFound
    case signalFailed(Int32)
    case purgeUnavailable

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(output): return L("memory.error.command-failed", output)
        case .invalidPID: return L("memory.error.invalid-pid")
        case let .protectedProcess(name): return L("memory.error.protected-process", name)
        case .permissionDenied: return L("memory.error.permission-denied")
        case .processNotFound: return L("memory.error.process-not-found")
        case let .signalFailed(code): return L("memory.error.signal-failed", code)
        case .purgeUnavailable: return L("memory.error.purge-unavailable")
        }
    }
}

public enum MemoryService {
    public static let purgeOperation = MemoryMaintenanceOperation(
        kind: .developerFileCacheBenchmark,
        title: L("memory.purge.title"),
        explanation: L("memory.purge.explanation")
    )

    public static let protectedProcessNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "opendirectoryd", "securityd", "taskgated", "runningboardd"
    ]

    public static func snapshot() throws -> MemorySnapshot {
        guard let parsed = hostVMStatistics() else {
            throw MemoryServiceError.commandFailed("host_statistics64")
        }

        let physical = ProcessInfo.processInfo.physicalMemory
        let pageSize = parsed.pageSize
        let compressedPages = parsed.pages["Pages occupied by compressor"] ?? 0
        let statusLevel = memoryStatusPressureLevel()

        return MemorySnapshot(
            physical: physical,
            used: min(physical, usedBytes(pages: parsed.pages, pageSize: pageSize)),
            cached: cachedFilesBytes(pages: parsed.pages, pageSize: pageSize),
            compressed: compressedPages * pageSize,
            swapUsed: swapUsedBytes(),
            pressureFreePercent: nil,
            pressureLevel: pressureLevel(statusLevel: statusLevel)
        )
    }

    /// `host_statistics64` 直读，键名与 `vm_stat` 一致，给 `usedBytes` 复用。
    /// 仪表盘启动绝不能再走 `Shell.run`：`waitUntilExit` 会在主线程重入 runloop。
    public static func hostVMStatistics() -> (pageSize: UInt64, pages: [String: UInt64])? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_page_size)
        let pages: [String: UInt64] = [
            "Pages free": UInt64(info.free_count),
            "Pages active": UInt64(info.active_count),
            "Pages inactive": UInt64(info.inactive_count),
            "Pages speculative": UInt64(info.speculative_count),
            "Pages wired down": UInt64(info.wire_count),
            "Pages purgeable": UInt64(info.purgeable_count),
            "File-backed pages": UInt64(info.external_page_count),
            "Anonymous pages": UInt64(info.internal_page_count),
            "Pages occupied by compressor": UInt64(info.compressor_page_count)
        ]
        return (pageSize, pages)
    }

    /// `vm.swapusage` 的二进制结构，避免再 spawn `sysctl`。
    public static func swapUsedBytes() -> UInt64 {
        var usage = XSWUsage()
        var size = MemoryLayout<XSWUsage>.size
        let status = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return status == 0 ? usage.used : 0
    }

    /// 活动监视器口径的“已用内存”：App 匿名内存（扣除可随时回收的 purgeable）+ 联动 + 压缩。
    ///
    /// 不能用“物理内存 − 空闲页”估算：macOS 会把几乎所有未用内存拿去做文件缓存，
    /// 空闲页常年接近 0，那样算出的“已用”永远接近 100%，看起来像内存占用异常。
    public static func usedBytes(pages: [String: UInt64], pageSize: UInt64) -> UInt64 {
        let anonymous = pages["Anonymous pages"] ?? 0
        let purgeable = pages["Pages purgeable"] ?? 0
        let wired = pages["Pages wired down"] ?? 0
        let compressed = pages["Pages occupied by compressor"] ?? 0
        // purgeable 统计可能包含文件页，理论上可大于匿名页，做饱和减法。
        let appPages = anonymous > purgeable ? anonymous - purgeable : 0
        return (appPages + wired + compressed) * pageSize
    }

    /// 活动监视器「已缓存文件」：只计文件页。可清除页已从匿名内存里扣过，再加进来会重复计算。
    public static func cachedFilesBytes(pages: [String: UInt64], pageSize: UInt64) -> UInt64 {
        (pages["File-backed pages"] ?? 0) * pageSize
    }

    public static func processes(currentUserOnly: Bool = true) throws -> [ProcessMemoryInfo] {
        let result = try Shell.run("/bin/ps", ["-axo", "pid=,uid=,rss=,comm="])
        guard result.succeeded else { throw MemoryServiceError.commandFailed(result.combinedOutput) }
        return parsePS(result.stdout, currentUserID: currentUserOnly ? getuid() : nil)
            .map { process in
                let path = processExecutablePath(pid: process.pid) ?? process.executablePath
                return ProcessMemoryInfo(
                    pid: process.pid,
                    userID: process.userID,
                    rssBytes: process.rssBytes,
                    executablePath: path,
                    footprintBytes: processMemoryFootprint(pid: process.pid) ?? 0,
                    displayName: ProcessDisplayNameResolver.displayName(executablePath: path)
                )
            }
            .filter { $0.memoryBytes > 0 }
            .sorted(by: Self.isHigherMemoryUsage)
    }

    /// 活动监视器「内存」列：phys_footprint，包含压缩和仍记在该进程头上的换出页。
    /// 不能用 ps 的 RSS：大工具（IDA / Xcode）被压缩后 RSS 会掉到几十 MB，列表里就像“没开”。
    public static func processMemoryFootprint(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), rebound)
            }
        }
        guard status == 0 else { return nil }
        return info.ri_phys_footprint
    }

    public static func isHigherMemoryUsage(_ lhs: ProcessMemoryInfo, _ rhs: ProcessMemoryInfo) -> Bool {
        if lhs.memoryBytes == rhs.memoryBytes { return lhs.pid < rhs.pid }
        return lhs.memoryBytes > rhs.memoryBytes
    }

    public static func parseVMStat(_ text: String) -> (pageSize: UInt64, pages: [String: UInt64]) {
        // 兜底用本机运行时页大小(Apple Silicon 16K、Intel 4K),不写死某一种架构的常量。
        var pageSize = UInt64(vm_page_size)
        if let range = text.range(of: #"page size of \d+ bytes"#, options: .regularExpression) {
            let digits = text[range].filter(\.isNumber)
            pageSize = UInt64(digits) ?? pageSize
        }

        var pages: [String: UInt64] = [:]
        for rawLine in text.split(separator: "\n") {
            guard let colon = rawLine.firstIndex(of: ":") else { continue }
            let key = rawLine[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = rawLine[rawLine.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let count = UInt64(value) { pages[key] = count }
        }
        return (pageSize, pages)
    }

    public static func parseSwapUsage(_ text: String) -> UInt64 {
        guard let range = text.range(of: #"used = [0-9.]+[KMGTP]"#, options: .regularExpression) else {
            return 0
        }
        let token = text[range].replacingOccurrences(of: "used = ", with: "")
        return bytes(fromUnitString: token)
    }

    public static func parsePressureFreePercent(_ text: String) -> Int? {
        guard let range = text.range(of: #"free percentage:\s*\d+%"#, options: .regularExpression) else {
            return nil
        }
        return Int(text[range].filter(\.isNumber))
    }

    /// 活动监视器压力图同源：`kern.memorystatus_vm_pressure_level`。
    /// 0 正常，1 偏高，2 紧急，4 严重。不能用 memory_pressure -Q 的 free%。
    public static func memoryStatusPressureLevel() -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        return status == 0 ? Int(value) : nil
    }

    public static func pressureLevel(statusLevel: Int?) -> MemoryPressureLevel {
        guard let statusLevel else { return .unknown }
        switch statusLevel {
        case 0: return .healthy
        case 1: return .warning
        case 2, 3, 4: return .critical
        default: return statusLevel > 0 ? .critical : .unknown
        }
    }

    public static func parsePS(_ text: String, currentUserID: uid_t?) -> [ProcessMemoryInfo] {
        text.split(separator: "\n").compactMap { rawLine in
            let columns = rawLine.split(maxSplits: 3, omittingEmptySubsequences: true) {
                $0.isWhitespace
            }
            guard columns.count == 4,
                  let pid = Int32(columns[0]),
                  let uid = UInt32(columns[1]),
                  let rssKB = UInt64(columns[2]),
                  pid > 1,
                  currentUserID == nil || uid == currentUserID
            else { return nil }
            let path = String(columns[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return ProcessMemoryInfo(pid: pid, userID: uid, rssBytes: rssKB * 1024, executablePath: path)
        }
        .sorted(by: isHigherMemoryUsage)
    }

    public static func validatePID(
        _ pid: Int32,
        processName: String,
        ownPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws {
        guard pid > 1 else { throw MemoryServiceError.invalidPID }
        if pid == ownPID { throw MemoryServiceError.protectedProcess(L("memory.process.self")) }
        if protectedProcessNames.contains(processName) {
            throw MemoryServiceError.protectedProcess(processName)
        }
    }

    public static func send(_ signal: ProcessSignal, to process: ProcessMemoryInfo) throws {
        try validatePID(process.pid, processName: process.name)
        guard Darwin.kill(process.pid, signal.rawValue) == 0 else {
            switch errno {
            case EPERM: throw MemoryServiceError.permissionDenied
            case ESRCH: throw MemoryServiceError.processNotFound
            default: throw MemoryServiceError.signalFailed(errno)
            }
        }
    }

    public static var purgeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/purge")
    }

    public static func purgeFileCache() throws -> CommandResult {
        guard purgeAvailable else { throw MemoryServiceError.purgeUnavailable }
        let result = try AdminRunner.run(executable: "/usr/bin/purge")
        guard result.succeeded else { throw MemoryServiceError.commandFailed(result.combinedOutput) }
        return result
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// proc_pidpath 可能因进程退出或权限不足失败；这种情况静默使用 ps 提供的安全回退路径。
    public static func processExecutablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE 是 4 * MAXPATHLEN，但该 C 宏不能直接导入 Swift。
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func bytes(fromUnitString text: String) -> UInt64 {
        guard let suffix = text.last else { return 0 }
        let number = Double(text.dropLast()) ?? 0
        let multiplier: Double
        switch suffix {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_024 * 1_024
        case "G": multiplier = 1_024 * 1_024 * 1_024
        case "T": multiplier = 1_024 * 1_024 * 1_024 * 1_024
        case "P": multiplier = 1_024 * 1_024 * 1_024 * 1_024 * 1_024
        default: return UInt64(number)
        }
        return UInt64(max(0, number * multiplier))
    }
}

/// `sys/sysctl.h` 的 `xsw_usage`，Darwin 模块不一定导出这个结构体。
private struct XSWUsage {
    var total: UInt64 = 0
    var avail: UInt64 = 0
    var used: UInt64 = 0
    var pagesize: UInt32 = 0
    var encrypted: Int32 = 0
}

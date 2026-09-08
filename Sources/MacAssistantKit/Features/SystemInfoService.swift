import Foundation
import Darwin
import IOKit
import IOKit.ps

public struct InfoItem: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: String
    public let systemImage: String
    public let destination: AppDestination?

    public init(
        _ id: String,
        _ label: String,
        _ value: String,
        _ systemImage: String,
        destination: AppDestination? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.destination = destination
    }
}

public struct CPUTickSample: Sendable, Equatable {
    public let user: UInt64
    public let system: UInt64
    public let idle: UInt64
    public let nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var busy: UInt64 { user &+ system &+ nice }
    public var total: UInt64 { busy &+ idle }
}

public struct BatteryInfo: Sendable, Equatable {
    public var level: Double?
    public var state: String?
    public var cycleCount: Int?
    public var healthPercent: Int?
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var powerWatts: Double?

    public init(
        level: Double? = nil,
        state: String? = nil,
        cycleCount: Int? = nil,
        healthPercent: Int? = nil,
        minutesToEmpty: Int? = nil,
        minutesToFull: Int? = nil,
        powerWatts: Double? = nil
    ) {
        self.level = level
        self.state = state
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.powerWatts = powerWatts
    }

    public var shortText: String {
        var parts: [String] = []
        if let level {
            parts.append("\(Int((level * 100).rounded()))%")
        }
        if let state {
            parts.append(state)
        }
        return parts.joined(separator: " · ")
    }

    public var detailText: String {
        detailParts.joined(separator: " · ")
    }

    public var detailParts: [String] {
        var parts: [String] = []
        if let cycleCount {
            parts.append(L("sysinfo.battery.cycles", cycleCount))
        }
        if let healthPercent {
            parts.append(L("sysinfo.battery.health", healthPercent))
        }
        if let minutesToFull, let formatted = Self.formatMinutes(minutesToFull) {
            parts.append(L("sysinfo.battery.toFull", formatted))
        } else if let minutesToEmpty, let formatted = Self.formatMinutes(minutesToEmpty) {
            parts.append(L("sysinfo.battery.toEmpty", formatted))
        }
        if let powerWatts {
            parts.append(L("sysinfo.battery.power", String(format: "%.1f", powerWatts)))
        }
        return parts
    }

    public static func formatMinutes(_ minutes: Int) -> String? {
        guard minutes >= 0, minutes < 60 * 24 * 7 else { return nil }
        let hours = minutes / 60
        let remain = minutes % 60
        if hours > 0 {
            return L("sysinfo.battery.hm", hours, remain)
        }
        return L("sysinfo.battery.m", remain)
    }
}

public struct UsageHistorySample: Sendable, Equatable {
    public let capturedAt: Date
    public let cpuFraction: Double?
    public let memoryFraction: Double
    public let diskFraction: Double

    public init(capturedAt: Date = Date(), cpuFraction: Double?, memoryFraction: Double, diskFraction: Double) {
        self.capturedAt = capturedAt
        self.cpuFraction = cpuFraction
        self.memoryFraction = memoryFraction
        self.diskFraction = diskFraction
    }
}

public struct SystemLiveSample: Sendable {
    public var snapshot: SystemSnapshot
    public var cpuFraction: Double?
    public var network: NetworkRateSnapshot
    public var history: [UsageHistorySample]
}

public struct SystemLiveSampler: Sendable {
    public static let historyLimit = 30

    private var previousCPU: CPUTickSample?
    private var previousCounters: [NetworkLinkCounter]
    private var previousAt: Date
    private var sessionStart: [NetworkLinkCounter]
    private var history: [UsageHistorySample]

    public init(
        now: Date = Date(),
        cpu: CPUTickSample? = SystemInfoService.cpuTicks(),
        counters: [NetworkLinkCounter] = NetworkService.linkCounters()
    ) {
        previousCPU = cpu
        previousCounters = counters
        previousAt = now
        sessionStart = counters
        history = []
    }

    public mutating func tick(
        now: Date = Date(),
        snapshot: SystemSnapshot = SystemInfoService.snapshot(),
        cpu: CPUTickSample? = SystemInfoService.cpuTicks(),
        counters: [NetworkLinkCounter] = NetworkService.linkCounters()
    ) -> SystemLiveSample {
        var cpuFraction: Double?
        if let previousCPU, let cpu {
            cpuFraction = SystemInfoService.cpuFraction(previous: previousCPU, current: cpu)
        }
        if let cpu {
            previousCPU = cpu
        }

        var start = sessionStart
        for counter in counters where !start.contains(where: { $0.name == counter.name }) {
            start.append(counter)
        }
        sessionStart = start

        let network = NetworkService.rates(
            previous: previousCounters,
            current: counters,
            interval: now.timeIntervalSince(previousAt),
            sessionStart: start
        )
        previousCounters = counters
        previousAt = now

        history.append(
            UsageHistorySample(
                capturedAt: now,
                cpuFraction: cpuFraction,
                memoryFraction: snapshot.memoryUsedFraction,
                diskFraction: snapshot.diskUsedFraction
            )
        )
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }

        return SystemLiveSample(
            snapshot: snapshot,
            cpuFraction: cpuFraction,
            network: network,
            history: history
        )
    }
}

/// 系统信息快照,用于仪表盘展示。
public struct SystemSnapshot: Sendable {
    public var items: [InfoItem]
    public var memoryUsedFraction: Double
    public var memoryUsedText: String
    public var diskUsedFraction: Double
    public var diskUsedText: String
    public var diskPurgeableBytes: Int64
    public var diskPurgeableText: String
    public var batteryLevel: Double?
    public var batteryState: String?
    public var battery: BatteryInfo
    public var memoryPressure: MemoryPressureLevel
    public var capturedAt: Date
}

public enum SystemInfoService {

    public static func snapshot() -> SystemSnapshot {
        var items: [InfoItem] = []

        let pi = ProcessInfo.processInfo
        items.append(InfoItem("hostname", L("sysinfo.hostname"), pi.hostName, "network"))
        items.append(InfoItem("macos", "macOS", macOSVersion(), "apple.logo"))
        items.append(InfoItem("model", L("sysinfo.model"), sysctlString("hw.model") ?? L("sysinfo.unknown"), "desktopcomputer"))
        items.append(InfoItem("chip", L("sysinfo.chip"), sysctlString("machdep.cpu.brand_string") ?? L("sysinfo.unknown"), "cpu"))
        items.append(InfoItem("architecture", L("sysinfo.architecture"), HostArchitecture.summary, "cpu"))

        let physical = sysctlInt("hw.physicalcpu") ?? 0
        let logical = sysctlInt("hw.logicalcpu") ?? UInt64(pi.activeProcessorCount)
        items.append(InfoItem(
            "cpu.cores",
            L("sysinfo.cpu.cores"),
            L("sysinfo.cpu.cores.value", String(physical), String(logical)),
            "cpu.fill"
        ))

        let total = pi.physicalMemory
        items.append(InfoItem(
            "memory.total",
            L("sysinfo.memory.total"),
            MemoryService.formatBytes(total),
            "memorychip",
            destination: .memory
        ))
        items.append(InfoItem("uptime", L("sysinfo.uptime"), formatUptime(secondsSinceBoot()), "clock"))

        let mem = memoryUsage(total: total)
        items.append(InfoItem(
            "memory.used",
            L("sysinfo.memory.used"),
            "\(MemoryService.formatBytes(mem.used)) / \(MemoryService.formatBytes(total))",
            "gauge.with.dots.needle.67percent",
            destination: .memory
        ))

        let disk = diskUsage()
        items.append(InfoItem(
            "disk",
            L("sysinfo.disk"),
            "\(FileSystemHelper.humanReadableSize(disk.used)) / \(FileSystemHelper.humanReadableSize(disk.total))",
            "internaldrive"
        ))

        let battery = batteryInfo()
        if battery.level != nil || battery.state != nil {
            items.append(InfoItem("battery", L("sysinfo.battery"), battery.shortText, "battery.100"))
        }

        return SystemSnapshot(
            items: items,
            memoryUsedFraction: total > 0 ? Double(mem.used) / Double(total) : 0,
            memoryUsedText: "\(MemoryService.formatBytes(mem.used)) / \(MemoryService.formatBytes(total))",
            diskUsedFraction: disk.total > 0 ? Double(disk.used) / Double(disk.total) : 0,
            diskUsedText: "\(FileSystemHelper.humanReadableSize(disk.used)) / \(FileSystemHelper.humanReadableSize(disk.total))",
            diskPurgeableBytes: disk.purgeable,
            diskPurgeableText: disk.purgeable > 0
                ? FileSystemHelper.humanReadableSize(disk.purgeable)
                : "",
            batteryLevel: battery.level,
            batteryState: battery.state,
            battery: battery,
            memoryPressure: MemoryService.pressureLevel(statusLevel: MemoryService.memoryStatusPressureLevel()),
            capturedAt: Date()
        )
    }

    // MARK: - CPU

    public static func cpuTicks() -> CPUTickSample? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return CPUTickSample(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    public static func cpuFraction(previous: CPUTickSample, current: CPUTickSample) -> Double? {
        let busy = wrappingDelta32(previous.busy, current.busy)
        let total = wrappingDelta32(previous.total, current.total)
        guard total > 0 else { return nil }
        return min(1, Double(busy) / Double(total))
    }

    // MARK: - sysctl 辅助

    public static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    public static func sysctlInt(_ key: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname(key, &value, &size, nil, 0) == 0 { return value }
        var value32: UInt32 = 0
        size = MemoryLayout<UInt32>.size
        if sysctlbyname(key, &value32, &size, nil, 0) == 0 { return UInt64(value32) }
        return nil
    }

    // MARK: - 具体信息

    static func macOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let build = sysctlString("kern.osversion") ?? ""
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)\(build.isEmpty ? "" : " (\(build))")"
    }

    /// 与内存工具页共用活动监视器口径，避免两个页面对“已用内存”给出不同数字。
    static func memoryUsage(total: UInt64) -> (used: UInt64, free: UInt64) {
        guard let parsed = MemoryService.hostVMStatistics() else {
            return (0, total)
        }
        let used = min(total, MemoryService.usedBytes(pages: parsed.pages, pageSize: parsed.pageSize))
        return (used, total - used)
    }

    static func diskUsage() -> (used: Int64, total: Int64, free: Int64, purgeable: Int64) {
        let volume = URL(fileURLWithPath: "/")
        let values = try? volume.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        if let totalCapacity = values?.volumeTotalCapacity, totalCapacity > 0 {
            let total = Int64(totalCapacity)
            let free = Int64(values?.volumeAvailableCapacity ?? 0)
            let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
            return (max(total - free, 0), total, free, max(important - free, 0))
        }

        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") else {
            return (0, 0, 0, 0)
        }
        let total = (attrs[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return (total - free, total, free, 0)
    }

    static func batteryInfo() -> BatteryInfo {
        var info = batteryInfo(from: copyPowerSourceDescriptions(), extras: smartBatteryProperties())
        if info.minutesToEmpty == nil,
           info.state == L("sysinfo.battery.discharging") {
            let estimate = IOPSGetTimeRemainingEstimate()
            if estimate != kIOPSTimeRemainingUnknown,
               estimate != kIOPSTimeRemainingUnlimited,
               estimate > 0 {
                info.minutesToEmpty = saneMinutes(Int(estimate / 60))
            }
        }
        return info
    }

    /// 把 IOKit 电源描述收成可测的字典，避免仪表盘启动再去 spawn `pmset`。
    static func battery(from descriptions: [[String: Any]]) -> (level: Double?, state: String?) {
        let info = batteryInfo(from: descriptions, extras: [:])
        return (info.level, info.state)
    }

    static func batteryInfo(from descriptions: [[String: Any]], extras: [String: Any]) -> BatteryInfo {
        for description in descriptions {
            let type = description[kIOPSTypeKey as String] as? String
            guard type == kIOPSInternalBatteryType as String else { continue }

            let merged = mergeBatteryKeys(description, extras)
            let current = intValue(merged[kIOPSCurrentCapacityKey as String] ?? merged["CurrentCapacity"])
            let maximum = intValue(merged[kIOPSMaxCapacityKey as String] ?? merged["MaxCapacity"])
            let level: Double?
            if let current, let maximum, maximum > 0 {
                level = Double(current) / Double(maximum > 100 ? maximum : max(maximum, 1))
                if maximum <= 100 {
                    // 部分机器把容量写成百分比，电流也是 0–100。
                }
            } else {
                level = nil
            }

            var info = BatteryInfo(
                level: level.map { min(1, max(0, $0)) },
                state: batteryState(from: merged),
                cycleCount: intValue(firstValue(merged, keys: ["CycleCount", "Cycle Count"])),
                healthPercent: batteryHealthPercent(merged),
                minutesToEmpty: saneMinutes(intValue(firstValue(merged, keys: [
                    kIOPSTimeToEmptyKey as String, "TimeToEmpty", "Time to Empty", "TimeRemaining"
                ]))),
                minutesToFull: saneMinutes(intValue(firstValue(merged, keys: [
                    kIOPSTimeToFullChargeKey as String, "TimeToFullCharge", "Time to Full Charge"
                ]))),
                powerWatts: batteryPowerWatts(merged)
            )

            if info.state == L("sysinfo.battery.charging"), info.minutesToFull == nil {
                info.minutesToFull = saneMinutes(intValue(firstValue(merged, keys: ["TimeRemaining"])))
            }
            if info.state != L("sysinfo.battery.charging") {
                info.minutesToFull = nil
            }
            if info.state != L("sysinfo.battery.discharging") {
                info.minutesToEmpty = nil
            }
            return info
        }
        return BatteryInfo()
    }

    /// 和系统设置「最大容量」同一口径：先读苹果算好的百分比，再退到 NCC / 设计容量。
    /// 即时 `AppleRawMaxCapacity` 会随温度和电量晃几十分钟安时，拿它当健康度会比设置低 2～5 点。
    private static func batteryHealthPercent(_ description: [String: Any]) -> Int? {
        if let percent = intValue(firstValue(description, keys: [
            "Maximum Capacity Percent", "MaximumCapacityPercent", "MaxCapacityPercent"
        ])), (0...100).contains(percent) {
            return percent
        }

        let design = intValue(firstValue(description, keys: [
            kIOPSDesignCapacityKey as String, "DesignCapacity", "Design Capacity"
        ]))
        let nominal = intValue(firstValue(description, keys: [
            "NominalChargeCapacity", kIOPSNominalCapacityKey as String, "Nominal Capacity"
        ]))
        if let ratio = capacityRatioPercent(current: nominal, design: design) {
            return ratio
        }

        let rawMax = intValue(firstValue(description, keys: ["AppleRawMaxCapacity"]))
        if let ratio = capacityRatioPercent(current: rawMax, design: design) {
            return ratio
        }

        let maxCapacity = intValue(firstValue(description, keys: [
            kIOPSMaxCapacityKey as String, "MaxCapacity", "Max Capacity"
        ]))
        if let ratio = capacityRatioPercent(current: maxCapacity, design: design) {
            return ratio
        }
        if let maxCapacity, maxCapacity <= 100, maxCapacity > 0, design == nil || design! <= 100 {
            return maxCapacity
        }
        return nil
    }

    private static func capacityRatioPercent(current: Int?, design: Int?) -> Int? {
        guard let current, let design, design > 100, current > 0 else { return nil }
        return clampPercent(Int((Double(current) / Double(design) * 100).rounded()))
    }

    private static func batteryPowerWatts(_ description: [String: Any]) -> Double? {
        let voltage = intValue(firstValue(description, keys: [kIOPSVoltageKey as String, "Voltage"]))
        let amperage = intValue(firstValue(description, keys: [
            "Amperage", "InstantAmperage"
        ]))
        guard let voltage, let amperage, voltage > 0, amperage != 0 else { return nil }
        return abs(Double(voltage) * Double(amperage)) / 1_000_000
    }

    private static func batteryState(from description: [String: Any]) -> String? {
        if boolValue(description[kIOPSIsChargingKey as String]) == true {
            return L("sysinfo.battery.charging")
        }
        if boolValue(description[kIOPSIsChargedKey as String]) == true {
            return L("sysinfo.battery.charged")
        }
        let power = description[kIOPSPowerSourceStateKey as String] as? String
        if power == kIOPSBatteryPowerValue as String {
            return L("sysinfo.battery.discharging")
        }
        if power == kIOPSACPowerValue as String {
            return L("sysinfo.battery.ac-power")
        }
        return nil
    }

    private static func copyPowerSourceDescriptions() -> [[String: Any]] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return [] }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return []
        }
        return sources.compactMap { source in
            IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
        }
    }

    static func smartBatteryProperties() -> [String: Any] {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return [:] }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else {
            return [:]
        }
        return dictionary
    }

    private static func mergeBatteryKeys(_ description: [String: Any], _ extras: [String: Any]) -> [String: Any] {
        var merged = extras
        for (key, value) in description {
            merged[key] = value
        }
        return merged
    }

    private static func firstValue(_ dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dictionary[key] { return value }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? UInt64 { return Int(clamping: number) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func saneMinutes(_ value: Int?) -> Int? {
        guard let value, value >= 0, value < 60 * 24 * 7 else { return nil }
        return value
    }

    private static func clampPercent(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    static func wrappingDelta32(_ previous: UInt64, _ current: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        return (UInt64(UInt32.max) &- previous) &+ current &+ 1
    }

    /// 距开机的墙钟时间。`ProcessInfo.systemUptime` 不含睡眠，合盖几天后会比 `uptime` 少一截。
    static func secondsSinceBoot(now: Date = Date(), boot: timeval? = copyBootTime()) -> TimeInterval {
        guard let boot, boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let bootDate = Date(
            timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000
        )
        return max(0, now.timeIntervalSince(bootDate))
    }

    static func copyBootTime() -> timeval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return nil
        }
        return boot
    }

    static func formatUptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if days > 0 { parts.append(L("sysinfo.uptime.days", days)) }
        if hours > 0 { parts.append(L("sysinfo.uptime.hours", hours)) }
        parts.append(L("sysinfo.uptime.minutes", minutes))
        return parts.joined(separator: " ")
    }
}

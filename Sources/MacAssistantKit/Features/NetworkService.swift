import Foundation
import Darwin

public struct NetworkInterface: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let ipv4: String

    public init(name: String, ipv4: String) {
        self.id = name
        self.name = name
        self.ipv4 = ipv4
    }
}

public struct NetworkLinkCounter: Sendable, Equatable {
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct NetworkInterfaceRate: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double
}

public struct NetworkRateSnapshot: Sendable, Equatable {
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double
    public let sessionBytesIn: UInt64
    public let sessionBytesOut: UInt64
    public let interfaces: [NetworkInterfaceRate]

    public static let empty = NetworkRateSnapshot(
        bytesInPerSecond: 0,
        bytesOutPerSecond: 0,
        sessionBytesIn: 0,
        sessionBytesOut: 0,
        interfaces: []
    )
}

public struct ListeningPort: Identifiable, Sendable {
    public let id = UUID()
    public let command: String
    public let pid: String
    public let name: String
    public let node: String

    public init(command: String, pid: String, name: String, node: String) {
        self.command = command
        self.pid = pid
        self.name = name
        self.node = node
    }

    public func refers(to port: Int) -> Bool {
        name.hasSuffix(":\(port)")
    }
}

public enum NetworkService {

    /// 通过 getifaddrs 读取本机各网卡的 IPv4 地址(排除回环)。
    public static func localInterfaces() -> [NetworkInterface] {
        var result: [NetworkInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let addr = current.pointee.ifa_addr
            if let addr, addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" {
                        result.append(NetworkInterface(name: name, ipv4: ip))
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return result
    }

    /// 非回环网卡累计收发字节。计数器可能是 32 位回绕，算速率时按回绕处理。
    public static func linkCounters() -> [NetworkLinkCounter] {
        var result: [String: NetworkLinkCounter] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let raw = current.pointee.ifa_data else { continue }

            let name = String(cString: current.pointee.ifa_name)
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            result[name] = NetworkLinkCounter(
                name: name,
                bytesIn: UInt64(data.ifi_ibytes),
                bytesOut: UInt64(data.ifi_obytes)
            )
        }
        return result.values.sorted { $0.name < $1.name }
    }

    public static func rates(
        previous: [NetworkLinkCounter],
        current: [NetworkLinkCounter],
        interval: TimeInterval,
        sessionStart: [NetworkLinkCounter]
    ) -> NetworkRateSnapshot {
        let names = Set(previous.map(\.name)).union(current.map(\.name))
        let measuredInterval = interval >= 0.15 ? interval : nil
        var interfaces: [NetworkInterfaceRate] = []
        var totalIn: Double = 0
        var totalOut: Double = 0
        var sessionIn: UInt64 = 0
        var sessionOut: UInt64 = 0

        for name in names.sorted() {
            let currentIn = current.first { $0.name == name }?.bytesIn ?? 0
            let currentOut = current.first { $0.name == name }?.bytesOut ?? 0
            let previousIn = previous.first { $0.name == name }?.bytesIn ?? currentIn
            let previousOut = previous.first { $0.name == name }?.bytesOut ?? currentOut
            let startIn = sessionStart.first { $0.name == name }?.bytesIn ?? currentIn
            let startOut = sessionStart.first { $0.name == name }?.bytesOut ?? currentOut

            let deltaIn = wrappingDelta32(previousIn, currentIn)
            let deltaOut = wrappingDelta32(previousOut, currentOut)
            let inbound = measuredInterval.map { Double(deltaIn) / $0 } ?? 0
            let outbound = measuredInterval.map { Double(deltaOut) / $0 } ?? 0
            totalIn += inbound
            totalOut += outbound
            sessionIn += wrappingDelta32(startIn, currentIn)
            sessionOut += wrappingDelta32(startOut, currentOut)

            if inbound >= 1 || outbound >= 1 {
                interfaces.append(
                    NetworkInterfaceRate(name: name, bytesInPerSecond: inbound, bytesOutPerSecond: outbound)
                )
            }
        }

        return NetworkRateSnapshot(
            bytesInPerSecond: totalIn,
            bytesOutPerSecond: totalOut,
            sessionBytesIn: sessionIn,
            sessionBytesOut: sessionOut,
            interfaces: interfaces
        )
    }

    public static func formatBytesPerSecond(_ rate: Double) -> String {
        let bytes = Int64(max(0, rate.rounded()))
        return L("network.rate.perSecond", FileSystemHelper.humanReadableSize(bytes))
    }

    static func wrappingDelta32(_ previous: UInt64, _ current: UInt64) -> UInt64 {
        if current >= previous { return current - previous }
        return (UInt64(UInt32.max) &- previous) &+ current &+ 1
    }

    /// 列出占用某端口的进程（LISTEN 以外的状态也会出现）。
    public static func processes(onPort port: Int) -> [PortProcess] {
        guard port > 0, port <= 65535 else { return [] }
        guard let r = try? Shell.run("/usr/sbin/lsof", ["-nP", "-i", ":\(port)"]) else { return [] }
        var seen = Set<String>()
        var result: [PortProcess] = []
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2 else { continue }
            if seen.insert(parts[1]).inserted {
                result.append(PortProcess(pid: parts[1], command: parts[0]))
            }
        }
        return result
    }

    public static func killCommand(pids: [String], force: Bool) -> String {
        "kill \(force ? "-9" : "-15") \(pids.joined(separator: " "))"
    }

    @discardableResult
    public static func kill(pids: [String], force: Bool) throws -> CommandResult {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let validated = pids.compactMap(Int32.init)
        guard validated.count == pids.count, validated.allSatisfy({ $0 > 1 && $0 != selfPid }) else {
            throw NSError(
                domain: "NetworkService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("repair.error.invalid-pid-list")]
            )
        }
        guard !validated.isEmpty else {
            return CommandResult(exitCode: 0, stdout: L("repair.kill.no-process"), stderr: "")
        }
        let arguments = [force ? "-9" : "-15"] + validated.map(String.init)
        let local = try Shell.run("/bin/kill", arguments)
        if needsPrivilege(local) {
            return try AdminRunner.run(executable: "/bin/kill", arguments: arguments)
        }
        return local
    }

    private static func needsPrivilege(_ result: CommandResult) -> Bool {
        if result.succeeded { return false }
        let text = (result.stdout + result.stderr).lowercased()
        return text.contains("operation not permitted")
            || text.contains("permission denied")
            || text.contains("not permitted")
            || text.contains("eperm")
    }

    /// 列出处于 LISTEN 状态的 TCP 端口(基于 lsof)。
    public static func listeningPorts() -> [ListeningPort] {
        guard let result = try? Shell.run("/usr/sbin/lsof",
                                          ["-nP", "-iTCP", "-sTCP:LISTEN"]),
              result.succeeded || !result.stdout.isEmpty else { return [] }
        var ports: [ListeningPort] = []
        for line in result.stdout.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 9 else { continue }
            ports.append(ListeningPort(command: parts[0], pid: parts[1],
                                       name: parts[8], node: parts[7]))
        }
        return ports
    }

    /// 尝试获取公网 IP(需要网络访问,可能失败)。
    public static func publicIP() -> String? {
        for host in ["https://api.ipify.org", "https://ifconfig.me/ip"] {
            if let result = try? Shell.run("/usr/bin/curl", ["-s", "--max-time", "6", host]),
               result.succeeded {
                let ip = result.trimmedOutput
                if !ip.isEmpty, ip.count < 64 { return ip }
            }
        }
        return nil
    }

    public static func ping(host: String, count: Int = 4) throws -> CommandResult {
        try Shell.run("/sbin/ping", ["-c", "\(count)", host])
    }

    /// 刷新 DNS 缓存需要管理员权限。
    public static let flushDNSCommand = "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"

    @discardableResult
    public static func flushDNS() throws -> CommandResult {
        try AdminRunner.runSequence([
            try AdminRunner.PrivilegedCommand(
                executable: "/usr/bin/dscacheutil",
                arguments: ["-flushcache"]
            ),
            try AdminRunner.PrivilegedCommand(
                executable: "/usr/bin/killall",
                arguments: ["-HUP", "mDNSResponder"]
            )
        ])
    }
}

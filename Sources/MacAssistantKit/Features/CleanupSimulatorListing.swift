import Foundation

/// 从 `simctl -j` 读出不可用 runtime / 设备，只用于展示，删除仍走官方命令。
public struct CleanupSimulatorListing: Equatable, Sendable {
    public var unavailableRuntimeCount: Int
    public var unavailableDeviceNames: [String]

    public init(unavailableRuntimeCount: Int, unavailableDeviceNames: [String]) {
        self.unavailableRuntimeCount = unavailableRuntimeCount
        self.unavailableDeviceNames = unavailableDeviceNames
    }

    public static let empty = CleanupSimulatorListing(unavailableRuntimeCount: 0, unavailableDeviceNames: [])

    public static func parse(runtimes: [String: Any], devices: [String: Any]) -> CleanupSimulatorListing {
        let runtimeCount = runtimes.values.reduce(0) { count, value in
            guard let runtime = value as? [String: Any] else { return count }
            let deletable = runtime["deletable"] as? Bool ?? false
            return deletable ? count + 1 : count
        }

        var names: [String] = []
        if let byRuntime = devices["devices"] as? [String: [[String: Any]]] {
            for devicesInRuntime in byRuntime.values {
                for device in devicesInRuntime {
                    let available = device["isAvailable"] as? Bool ?? true
                    guard !available, let name = device["name"] as? String else { continue }
                    names.append(name)
                }
            }
        }

        return CleanupSimulatorListing(
            unavailableRuntimeCount: runtimeCount,
            unavailableDeviceNames: names.sorted()
        )
    }

    public static func load() -> CleanupSimulatorListing {
        let runtimes = json("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]) ?? [:]
        let devices = json("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"]) ?? [:]
        return parse(runtimes: runtimes, devices: devices)
    }

    private static func json(_ executable: String, _ arguments: [String]) -> [String: Any]? {
        guard let result = try? Shell.run(executable, arguments), result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}

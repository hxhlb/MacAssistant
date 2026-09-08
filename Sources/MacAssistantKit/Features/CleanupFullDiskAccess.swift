import Foundation

public enum CleanupFullDiskAccessStatus: String, Equatable, Sendable {
    case granted
    case denied
    case unknown
}

/// 独立于逐项 scan 的 FDA 真读探测：用 `contentsOfDirectory` / `FileHandle`，不用 `isReadableFile`。
/// 只碰 TCC.db、Safari、Mail，避免注册到 Messages / Contacts / Calendars。
public struct CleanupFullDiskAccessProbe: Sendable {
    public var readDirectory: @Sendable (URL) throws -> Void
    public var openFile: @Sendable (URL) throws -> Void
    public var itemExists: @Sendable (URL) -> Bool

    public init(
        readDirectory: @escaping @Sendable (URL) throws -> Void,
        openFile: @escaping @Sendable (URL) throws -> Void,
        itemExists: @escaping @Sendable (URL) -> Bool
    ) {
        self.readDirectory = readDirectory
        self.openFile = openFile
        self.itemExists = itemExists
    }

    public static let live = CleanupFullDiskAccessProbe(
        readDirectory: { url in
            _ = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
        },
        openFile: { url in
            let handle = try FileHandle(forReadingFrom: url)
            try handle.close()
        },
        itemExists: { FileManager.default.fileExists(atPath: $0.path) }
    )

    public func probe(homeDirectory: URL) -> CleanupFullDiskAccessStatus {
        let home = homeDirectory.standardizedFileURL
        let doors: [(URL, Bool)] = [
            (home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"), false),
            (home.appendingPathComponent("Library/Safari"), true),
            (home.appendingPathComponent("Library/Mail"), true),
            (home.appendingPathComponent("Library/Containers/com.apple.Safari"), true)
        ]

        var attempted = 0
        var succeeded = 0
        for (url, isDirectory) in doors {
            guard itemExists(url) else { continue }
            attempted += 1
            do {
                if isDirectory {
                    try readDirectory(url)
                } else {
                    try openFile(url)
                }
                succeeded += 1
            } catch {
                continue
            }
        }

        if attempted == 0 { return .unknown }
        return succeeded > 0 ? .granted : .denied
    }
}

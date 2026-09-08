import AppKit
import Foundation

public enum MacAppLaunchError: LocalizedError {
    case notAnApp
    case missing

    public var errorDescription: String? {
        switch self {
        case .notAnApp: return L("macapp.launch.error.notAnApp")
        case .missing: return L("macapp.launch.error.missing")
        }
    }
}

/// 打开本机 .app；`newInstance` 对应 `open -n`，不改 Bundle、不拷贝文件。
public enum MacAppLaunchService {
    public static func open(_ app: URL, newInstance: Bool = false) async throws {
        guard app.pathExtension.lowercased() == "app" else { throw MacAppLaunchError.notAnApp }
        guard FileSystemHelper.isDirectory(app) else { throw MacAppLaunchError.missing }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = newInstance
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

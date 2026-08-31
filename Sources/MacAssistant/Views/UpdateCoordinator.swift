import AppKit
import Foundation
import SwiftUI
import MacAssistantKit

/// 「检查更新」的界面状态机。逻辑都在 `MacAssistantKit.UpdateService` 里,这里只负责
/// 把结果翻译成弹窗和「关于」页上的文案,以及用户确认后的下载。
@MainActor
final class UpdateCoordinator: ObservableObject {

    enum ManualState: Equatable {
        case idle
        case checking
        case finished(String)
    }

    enum DownloadState: Equatable {
        case idle
        case downloading
        case finished(URL)
        case failed(String)
    }

    /// 非 nil 时展示更新弹窗。
    @Published private(set) var pendingUpdate: UpdateInfo?
    @Published private(set) var manualState: ManualState = .idle
    @Published private(set) var downloadState: DownloadState = .idle
    @Published var automaticCheckEnabled: Bool {
        didSet { preferences.automaticCheckEnabled = automaticCheckEnabled }
    }

    let currentVersion: String
    private let preferences: UpdatePreferences
    private let service: UpdateService

    init(preferences: UpdatePreferences = UpdatePreferences()) {
        let version = AppVersionSource.current
        self.currentVersion = version
        self.preferences = preferences
        self.service = UpdateService(currentVersion: version, preferences: preferences)
        self.automaticCheckEnabled = preferences.automaticCheckEnabled
    }

    var isChecking: Bool { manualState == .checking }
    var isDownloading: Bool { downloadState == .downloading }

    /// 弹窗的 `isPresented` 绑定;用户点任意按钮或按 Esc 都会把它置回 false。
    var isShowingUpdateAlert: Bool {
        get { pendingUpdate != nil }
        set { if !newValue { pendingUpdate = nil } }
    }

    var statusText: String? {
        if isDownloading { return "正在下载更新…" }
        switch downloadState {
        case .finished:
            return "已下载到「下载」文件夹。"
        case .failed(let message):
            return message
        case .idle, .downloading:
            break
        }
        switch manualState {
        case .idle:
            return nil
        case .checking:
            return "正在检查…"
        case .finished(let message):
            return message
        }
    }

    /// 启动时调用。整个过程异步,失败静默,不阻塞界面。
    func runAutomaticCheckIfDue() async {
        guard !Self.isDisabledByEnvironment else { return }
        guard case .prompt(let info) = await service.runAutomaticCheck() else { return }
        pendingUpdate = info
    }

    func runManualCheck() async {
        guard !isChecking, !isDownloading else { return }
        manualState = .checking
        let result = await service.runManualCheck()
        manualState = .finished(result.message)
        if case .updateAvailable(let info) = result {
            pendingUpdate = info
        }
    }

    func alertMessage(for info: UpdateInfo) -> String {
        var lines = ["当前版本 \(currentVersion)，最新版本 \(info.version)。"]
        let summary = info.releaseNotesSummary()
        if !summary.isEmpty { lines.append(summary) }
        return lines.joined(separator: "\n\n")
    }

    /// 有可信附件就下载到「下载」;否则打开 Release 页。
    func downloadPendingUpdate() {
        guard let info = pendingUpdate else { return }
        pendingUpdate = nil
        Task { await download(info) }
    }

    func revealDownloadedFile() {
        if case .finished(let url) = downloadState {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// 记住这个版本号,之后不再为它自动弹窗;更高的版本仍然会提示。
    func skipPendingVersion() {
        if let pendingUpdate { preferences.skip(pendingUpdate) }
        self.pendingUpdate = nil
    }

    func remindLater() {
        pendingUpdate = nil
    }

    private func download(_ info: UpdateInfo) async {
        guard let remote = info.downloadURL, ReleaseDownload.isTrusted(remote) else {
            NSWorkspace.shared.open(info.releaseURL)
            return
        }
        downloadState = .downloading
        do {
            let file = try await Self.fetchRelease(from: remote, currentVersion: currentVersion)
            downloadState = .finished(file)
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            downloadState = .failed("下载失败，已改为打开 GitHub 发布页。")
            NSWorkspace.shared.open(info.releaseURL)
        }
    }

    /// 图标探测和自动化测试不该打网络。
    private static var isDisabledByEnvironment: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["MACASSISTANT_ICON_PROBE"] == "1"
            || environment["MACASSISTANT_DISABLE_UPDATE_CHECK"] == "1"
    }

    private static func fetchRelease(from url: URL, currentVersion: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(UpdateService.userAgent(currentVersion: currentVersion), forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let destination = uniqueDownloadURL(named: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func uniqueDownloadURL(named fileName: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safeName = (fileName as NSString).lastPathComponent
        let fallback = safeName.isEmpty ? "Mac小助手.zip" : safeName
        var url = downloads.appendingPathComponent(fallback)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 2
        repeat {
            let name = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            url = downloads.appendingPathComponent(name)
            index += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }
}

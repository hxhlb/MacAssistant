import Darwin
import Foundation

/// 一个可清理目标(将删除其中每个目录的“内容”,保留目录本身)。
public final class CleanupTarget: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let paths: [URL]
    @Published public var size: Int64 = 0
    @Published public var selected: Bool = false

    public init(id: String, name: String, detail: String, paths: [URL]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.paths = paths
    }

    public var existingPaths: [URL] {
        paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

public struct CleanupFileActions: @unchecked Sendable {
    public var moveToTrash: (URL) throws -> URL
    public var removePermanently: (URL) throws -> Void

    public init(
        moveToTrash: @escaping (URL) throws -> URL,
        removePermanently: @escaping (URL) throws -> Void
    ) {
        self.moveToTrash = moveToTrash
        self.removePermanently = removePermanently
    }

    public static let live = CleanupFileActions(
        moveToTrash: { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            return (resultingURL as URL?) ?? url
        },
        removePermanently: { url in
            try FileManager.default.removeItem(at: url)
        }
    )
}

/// 用户级清理服务。普通项目只移入废纸篓；永久与外部工具动作必须走独立确认。
public enum CleanupService {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    public static var historyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacAssistant/Cleanup/operations.jsonl")
    }

    /// 每行一个 JSON 记录；保留最近 200 次，便于审计又避免日志无限增长。
    @discardableResult
    public static func appendHistory(
        _ summary: CleanupExecutionSummary,
        to url: URL = historyURL,
        completedAt: Date = Date()
    ) throws -> URL {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(CleanupHistoryEntry(summary: summary, completedAt: completedAt))
        let oldLines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(199) ?? []
        var data = Data(oldLines.joined(separator: "\n").utf8)
        if !data.isEmpty { data.append(0x0A) }
        data.append(encoded)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    public static func loadHistory(from url: URL = historyURL) throws -> [CleanupHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(CleanupHistoryEntry.self, from: Data($0.utf8)) }
    }

    public static func definitions(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CleanupTargetDefinition] {
        CleanupCatalog.definitions(homeDirectory: homeDirectory)
    }

    /// 旧版可变目标列表。系统清理页使用不可变 definition + scan report。
    public static func makeTargets() -> [CleanupTarget] {
        definitions().map {
            CleanupTarget(id: $0.id, name: $0.name, detail: $0.detail, paths: $0.paths)
        }
    }

    public static func makePolicy(
        definitions: [CleanupTargetDefinition],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CleanupPathPolicy {
        CleanupPathPolicy(
            homeDirectory: homeDirectory,
            allowedRoots: definitions.flatMap(\.paths)
        )
    }

    public static func makeScanPlan(
        seedDefinitions: [CleanupTargetDefinition]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        packageResolver: CleanupPackageCacheResolver = .live,
        fullDiskAccessProbe: CleanupFullDiskAccessProbe = .live
    ) -> CleanupScanPlan {
        CleanupDiscovery.makeScanPlan(
            seed: seedDefinitions ?? definitions(homeDirectory: homeDirectory),
            homeDirectory: homeDirectory,
            packageResolver: packageResolver,
            fullDiskAccessProbe: fullDiskAccessProbe
        )
    }

    public static func scan(
        plan: CleanupScanPlan,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (CleanupProgress) -> Void = { _ in }
    ) -> CleanupScanReport {
        let report = scan(
            definitions: plan.definitions,
            policy: plan.policy,
            cancellation: cancellation,
            progress: progress
        )
        guard !plan.blockedItems.isEmpty else { return report }
        return CleanupScanReport(
            items: report.items + plan.blockedItems,
            cancelled: report.cancelled,
            scannedAt: report.scannedAt
        )
    }

    public static func scan(
        definitions: [CleanupTargetDefinition],
        policy: CleanupPathPolicy,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (CleanupProgress) -> Void = { _ in }
    ) -> CleanupScanReport {
        let total = definitions.count
        guard total > 0 else {
            return CleanupScanReport(items: [], cancelled: false)
        }

        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var slots: [CleanupScanItem?]
            var completed = 0
            var wasCancelled = false

            init(count: Int) {
                slots = Array(repeating: nil, count: count)
            }

            func shouldStop(_ external: @Sendable () -> Bool) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if external() { wasCancelled = true }
                return wasCancelled
            }

            func finish(_ item: CleanupScanItem, at index: Int) -> Int {
                lock.lock()
                slots[index] = item
                if item.status == .cancelled { wasCancelled = true }
                completed += 1
                let done = completed
                lock.unlock()
                return done
            }
        }

        let box = Box(count: total)
        DispatchQueue.concurrentPerform(iterations: total) { index in
            let definition = definitions[index]
            if box.shouldStop(cancellation) {
                _ = box.finish(
                    CleanupScanItem(definition: definition, status: .cancelled, validatedPaths: []),
                    at: index
                )
                return
            }

            let item: CleanupScanItem
            if definition.action == .externalTool {
                item = CleanupScanItem(
                    definition: definition,
                    status: .excluded(L("cleanup.status.external-excluded")),
                    validatedPaths: []
                )
            } else {
                item = scan(
                    definition: definition,
                    policy: policy,
                    cancellation: { box.shouldStop(cancellation) }
                )
            }
            let done = box.finish(item, at: index)
            box.lock.lock()
            progress(
                CleanupProgress(
                    targetID: definition.id,
                    targetName: definition.name,
                    index: done,
                    total: total
                )
            )
            box.lock.unlock()
        }

        let items = CleanupDiscovery.coalesceSmallDynamicCaches(
            box.slots.compactMap { $0 }.filter { !CleanupDiscovery.shouldOmitDynamicItem($0) }
        )
        return CleanupScanReport(items: items, cancelled: box.wasCancelled)
    }

    /// 一行展开时看最大的几个子项。只读，不跟随符号链接，拒绝名单内的跳过。
    public static func largestChildren(
        of item: CleanupScanItem,
        limit: Int = 5,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CleanupBreakdownEntry] {
        var entries: [CleanupBreakdownEntry] = []
        let directoryRoots = item.validatedPaths.filter(\.isDirectory)
        if directoryRoots.count > 1 {
            for root in directoryRoots {
                if CleanupDeniedPaths.contains(root.canonicalURL, homeDirectory: homeDirectory) { continue }
                let measured = measure(
                    root: root,
                    homeDirectory: homeDirectory,
                    cancellation: { false }
                )
                if measured.bytes > 0 {
                    entries.append(
                        CleanupBreakdownEntry(
                            name: root.canonicalURL.lastPathComponent,
                            bytes: measured.bytes,
                            url: root.canonicalURL
                        )
                    )
                }
            }
            return Array(entries.sorted { $0.bytes > $1.bytes }.prefix(limit))
        }
        for root in directoryRoots {
            let children = CleanupDiscovery.listChildren(of: root.canonicalURL)
            for child in children {
                if CleanupDeniedPaths.contains(child, homeDirectory: homeDirectory) { continue }
                guard CleanupDiscovery.realDirectory(child) != nil || FileManager.default.fileExists(atPath: child.path) else {
                    continue
                }
                var info = stat()
                guard lstat(child.path, &info) == 0 else { continue }
                if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { continue }
                let measured = measure(
                    root: CleanupValidatedPath(
                        requestedURL: child,
                        canonicalURL: child.standardizedFileURL,
                        identity: CleanupFileIdentity(
                            device: UInt64(info.st_dev),
                            inode: UInt64(info.st_ino)
                        ),
                        isDirectory: (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                    ),
                    homeDirectory: homeDirectory,
                    cancellation: { false }
                )
                if measured.bytes > 0 {
                    entries.append(
                        CleanupBreakdownEntry(
                            name: child.lastPathComponent,
                            bytes: measured.bytes,
                            url: child
                        )
                    )
                }
            }
        }
        return Array(entries.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    public static func execute(
        report: CleanupScanReport,
        selectedIDs: Set<String>,
        policy: CleanupPathPolicy,
        allowPermanentTrash: Bool,
        actions: CleanupFileActions = .live,
        runtimeGuard: CleanupRuntimeGuard = .live,
        cancellation: @Sendable () -> Bool = { false },
        progress: @Sendable (CleanupProgress) -> Void = { _ in }
    ) -> CleanupExecutionSummary {
        let selectedItems = report.items.filter { selectedIDs.contains($0.id) }
        var results: [CleanupItemResult] = []
        var wasCancelled = false
        var processedRoots: [CleanupValidatedPath] = []

        for (index, item) in selectedItems.enumerated() {
            if cancellation() {
                wasCancelled = true
                results.append(
                    contentsOf: selectedItems[index...].map {
                        CleanupItemResult(
                            targetID: $0.id,
                            targetName: $0.definition.name,
                            outcome: .cancelled,
                            processedBytes: 0,
                            messages: [L("cleanup.message.cancelled-before-start")]
                        )
                    }
                )
                break
            }

            progress(
                CleanupProgress(
                    targetID: item.id,
                    targetName: item.definition.name,
                    index: index + 1,
                    total: selectedItems.count
                )
            )

            results.append(
                execute(
                    item: item,
                    policy: policy,
                    allowPermanentTrash: allowPermanentTrash,
                    actions: actions,
                    runtimeGuard: runtimeGuard,
                    cancellation: cancellation,
                    processedRoots: &processedRoots
                )
            )
            if results.last?.outcome == .cancelled {
                wasCancelled = true
            }
        }

        return CleanupExecutionSummary(results: results, cancelled: wasCancelled)
    }

    /// 计算目标占用的总字节数。
    public static func computeSize(_ target: CleanupTarget) -> Int64 {
        size(ofPaths: target.paths)
    }

    /// 计算一组路径的总占用（错误按 0 处理）。
    public static func size(ofPaths paths: [URL]) -> Int64 {
        paths.filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(0) { $0 + FileSystemHelper.size(at: $1) }
    }

    /// 普通路径统一移入废纸篓，不再静默永久删除。
    @discardableResult
    public static func cleanPaths(_ paths: [URL]) -> Int64 {
        let definition = CleanupTargetDefinition(
            id: "legacy",
            name: L("cleanup.legacy.name"),
            detail: L("cleanup.legacy.detail"),
            paths: paths,
            risk: .caution,
            action: .moveContentsToTrash,
            defaultSelected: false
        )
        let policy = CleanupPathPolicy(homeDirectory: home, allowedRoots: paths)
        let report = scan(definitions: [definition], policy: policy)
        return execute(
            report: report,
            selectedIDs: [definition.id],
            policy: policy,
            allowPermanentTrash: false
        ).processedBytes
    }

    @discardableResult
    public static func clean(_ target: CleanupTarget) -> Int64 {
        cleanPaths(target.paths)
    }

    private static func scan(
        definition: CleanupTargetDefinition,
        policy: CleanupPathPolicy,
        cancellation: @Sendable () -> Bool
    ) -> CleanupScanItem {
        var total: Int64 = 0
        var validated: [CleanupValidatedPath] = []
        var errors: [String] = []
        var missingCount = 0
        var rootPermissionCount = 0
        var deniedCount = 0
        var childPermissionHits = 0

        for path in definition.paths {
            if cancellation() {
                return CleanupScanItem(
                    definition: definition,
                    status: .cancelled,
                    validatedPaths: validated
                )
            }

            do {
                let root = try policy.validate(path)
                guard policy.isReadable(root) else {
                    rootPermissionCount += 1
                    errors.append(L("cleanup.message.no-read-permission", path.lastPathComponent))
                    continue
                }
                validated.append(root)
                let measured = measure(root: root, homeDirectory: policy.homeDirectory, cancellation: cancellation)
                total += measured.bytes
                errors.append(contentsOf: measured.errors)
                childPermissionHits += measured.permissionHits
                if measured.cancelled {
                    return CleanupScanItem(
                        definition: definition,
                        status: .cancelled,
                        validatedPaths: validated
                    )
                }
            } catch CleanupPathError.missing {
                missingCount += 1
            } catch CleanupPathError.denied {
                deniedCount += 1
                errors.append(L("cleanup.message.denied-skipped", path.lastPathComponent))
            } catch CleanupPathError.permissionDenied {
                rootPermissionCount += 1
                errors.append(L("cleanup.message.no-read-permission", path.lastPathComponent))
            } catch {
                errors.append(L("cleanup.message.detail", path.lastPathComponent, error.localizedDescription))
            }
        }

        // 多路径目标中部分路径不存在属于正常情况（例如没有 watchOS 设备支持），
        // 只有真实错误才降级为 partial。
        let status: CleanupScanStatus
        if definition.paths.isEmpty {
            status = .missing
        } else if deniedCount == definition.paths.count {
            status = .excluded(L("cleanup.status.denied-excluded"))
        } else if missingCount + deniedCount == definition.paths.count {
            status = .missing
        } else if missingCount == definition.paths.count {
            status = .missing
        } else if rootPermissionCount + missingCount + deniedCount == definition.paths.count && rootPermissionCount > 0 {
            status = .permissionDenied(errors.first ?? L("cleanup.message.no-read-permission.generic"))
        } else if childPermissionHits > 0 && total == 0 && rootPermissionCount == 0 {
            // 目录本身能 stat,但子项被 TCC 挡住:绝不能显示成「空 / 0 B」。
            status = .permissionDenied(errors.first ?? L("cleanup.message.no-read-permission.generic"))
        } else if !errors.isEmpty {
            status = .partial(total, aggregate(errors))
        } else {
            status = .measured(total)
        }
        return CleanupScanItem(definition: definition, status: status, validatedPaths: validated)
    }

    /// 轻量测量：只统计大小，不做逐文件策略校验。
    /// 安全性由删除边界保证——真正被移动的只有经过完整校验的顶层条目，
    /// 枚举器不跟随符号链接，因此这里无需再对每个后代做 realpath 检查。
    private static func measure(
        root: CleanupValidatedPath,
        homeDirectory: URL,
        cancellation: @Sendable () -> Bool
    ) -> (bytes: Int64, errors: [String], cancelled: Bool, permissionHits: Int) {
        if !root.isDirectory {
            guard let bytes = allocatedSize(at: root.canonicalURL) else {
                return (0, [L("cleanup.message.size-unreadable", root.canonicalURL.lastPathComponent)], false, 1)
            }
            return (bytes, [], false, 0)
        }

        var total: Int64 = 0
        var errors: [String] = []
        var permissionHits = 0
        var seenInodes = Set<CleanupFileIdentity>()
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root.canonicalURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                if FileSystemHelper.isAccessPermissionError(error) { permissionHits += 1 }
                errors.append(L("cleanup.message.detail", url.lastPathComponent, error.localizedDescription))
                return true
            }
        ) else {
            return (0, [L("cleanup.message.enumeration-failed")], false, 0)
        }

        let keySet = Set(keys)
        for case let url as URL in enumerator {
            if cancellation() { return (total, errors, true, permissionHits) }
            if CleanupDeniedPaths.contains(url, homeDirectory: homeDirectory) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keySet) else {
                errors.append(L("cleanup.message.attributes-unreadable", url.lastPathComponent))
                continue
            }
            if values.isSymbolicLink == true {
                // 符号链接随其父目录一并处理；枚举器本身不会跟随链接，大小不计入，也不算错误。
                continue
            }
            if values.isRegularFile == true {
                // 同一棵树里的硬链接只计一次，避免 pnpm / Cargo store 把可释放空间算炸。
                if let identity = fileIdentity(at: url), !seenInodes.insert(identity).inserted {
                    continue
                }
                total += Int64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                )
            }
        }
        return (total, errors, false, permissionHits)
    }

    /// 把可能上千条的逐文件错误压缩成前几条 + 总数，避免撑爆 UI 与内存。
    private static func aggregate(_ errors: [String], limit: Int = 3) -> [String] {
        guard errors.count > limit else { return errors }
        return Array(errors.prefix(limit)) + [L("cleanup.message.more-read-errors", errors.count - limit)]
    }

    private static func execute(
        item: CleanupScanItem,
        policy: CleanupPathPolicy,
        allowPermanentTrash: Bool,
        actions: CleanupFileActions,
        runtimeGuard: CleanupRuntimeGuard,
        cancellation: @Sendable () -> Bool,
        processedRoots: inout [CleanupValidatedPath]
    ) -> CleanupItemResult {
        let definition = item.definition
        guard definition.isSelectable else {
            return CleanupItemResult(
                targetID: item.id,
                targetName: definition.name,
                outcome: .skipped,
                processedBytes: 0,
                messages: [L("cleanup.message.not-file-cleanup")]
            )
        }
        if definition.action == .emptyTrashPermanently && !allowPermanentTrash {
            return CleanupItemResult(
                targetID: item.id,
                targetName: definition.name,
                outcome: .skipped,
                processedBytes: 0,
                messages: [L("cleanup.message.trash-needs-confirmation")]
            )
        }
        if definition.action == .moveContentsToTrash,
           let reason = runtimeGuard.skipReason(for: definition) {
            return CleanupItemResult(
                targetID: item.id,
                targetName: definition.name,
                outcome: .skipped,
                processedBytes: 0,
                messages: [reason]
            )
        }

        var processed: Int64 = 0
        var successes = 0
        var failures = 0
        var messages: [String] = []

        for requestedRoot in definition.paths {
            if cancellation() {
                return CleanupItemResult(
                    targetID: item.id,
                    targetName: definition.name,
                    outcome: .cancelled,
                    processedBytes: processed,
                    messages: messages + [L("cleanup.message.cancelled-no-rollback")]
                )
            }

            if processedRoots.contains(where: {
                let claimed = $0.requestedURL.standardizedFileURL.path
                let requested = requestedRoot.standardizedFileURL.path
                return requested == claimed || requested.hasPrefix(claimed + "/")
            }) {
                messages.append(L("cleanup.message.overlap-skipped", requestedRoot.lastPathComponent))
                continue
            }

            do {
                let root = try policy.validate(requestedRoot)
                guard policy.isReadable(root), policy.isWritable(root) else {
                    failures += 1
                    messages.append(L("cleanup.message.no-write-permission", requestedRoot.lastPathComponent))
                    continue
                }
                try policy.revalidate(root)

                if processedRoots.contains(where: {
                    $0.canonicalURL == root.canonicalURL || policy.contains(root, within: $0)
                }) {
                    continue
                }
                processedRoots.append(root)

                let candidates: [URL]
                if root.isDirectory {
                    candidates = try FileManager.default.contentsOfDirectory(
                        at: root.canonicalURL,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                } else {
                    candidates = [root.canonicalURL]
                }

                if candidates.isEmpty {
                    messages.append(L("cleanup.message.empty-directory", requestedRoot.lastPathComponent))
                }

                for candidateURL in candidates {
                    if cancellation() {
                        return CleanupItemResult(
                            targetID: item.id,
                            targetName: definition.name,
                            outcome: .cancelled,
                            processedBytes: processed,
                            messages: messages + [L("cleanup.message.cancelled-no-rollback")]
                        )
                    }

                    do {
                        try policy.revalidate(root)
                        let candidate = try policy.validate(candidateURL)
                        if root.isDirectory && !policy.contains(candidate, within: root) {
                            throw CleanupPathError.outsideAllowedRoots
                        }
                        try policy.revalidate(candidate)
                        if definition.action == .moveContentsToTrash {
                            // Bool? 在 Swift 5.10 上不能用 true/false/nil 穷尽 switch。
                            if let busy = runtimeGuard.isSQLiteFamilyBusy(candidate.canonicalURL) {
                                if busy {
                                    messages.append(
                                        L("cleanup.message.sqlite-busy", candidateURL.lastPathComponent)
                                    )
                                    continue
                                }
                            } else {
                                messages.append(
                                    L("cleanup.message.sqlite-unknown", candidateURL.lastPathComponent)
                                )
                                continue
                            }
                        }
                        let measurement = measure(
                            root: candidate,
                            homeDirectory: policy.homeDirectory,
                            cancellation: cancellation
                        )
                        if measurement.cancelled {
                            return CleanupItemResult(
                                targetID: item.id,
                                targetName: definition.name,
                                outcome: .cancelled,
                                processedBytes: processed,
                                messages: messages + [L("cleanup.message.cancelled-no-rollback")]
                            )
                        }
                        let bytes = measurement.bytes
                        if !measurement.errors.isEmpty {
                            messages.append(
                                L("cleanup.message.size-incomplete", candidateURL.lastPathComponent)
                            )
                        }
                        try policy.revalidate(root)
                        try policy.revalidate(candidate)

                        if definition.action == .emptyTrashPermanently {
                            try actions.removePermanently(candidate.canonicalURL)
                        } else {
                            _ = try actions.moveToTrash(candidate.canonicalURL)
                        }
                        processed += bytes
                        successes += 1
                    } catch CleanupPathError.missing {
                        messages.append(L("cleanup.message.gone-before-processing", candidateURL.lastPathComponent))
                    } catch CleanupPathError.symbolicLink {
                        messages.append(L("cleanup.message.symlink-skipped", candidateURL.lastPathComponent))
                    } catch CleanupPathError.denied {
                        messages.append(L("cleanup.message.denied-skipped", candidateURL.lastPathComponent))
                    } catch {
                        failures += 1
                        messages.append(L("cleanup.message.detail", candidateURL.lastPathComponent, error.localizedDescription))
                    }
                }
            } catch CleanupPathError.missing {
                messages.append(L("cleanup.message.path-missing", requestedRoot.lastPathComponent))
            } catch CleanupPathError.denied {
                messages.append(L("cleanup.message.denied-skipped", requestedRoot.lastPathComponent))
            } catch {
                failures += 1
                messages.append(L("cleanup.message.detail", requestedRoot.lastPathComponent, error.localizedDescription))
            }
        }

        // 空目录、路径不存在、符号链接跳过都是正常情况，不应把结果降级；
        // 只有真实失败才影响结论。
        let outcome: CleanupItemOutcome
        if failures > 0 && successes > 0 {
            outcome = .partial
        } else if failures > 0 {
            outcome = .failed
        } else if successes > 0 {
            outcome = .success
        } else {
            outcome = .skipped
        }
        return CleanupItemResult(
            targetID: item.id,
            targetName: definition.name,
            outcome: outcome,
            processedBytes: processed,
            messages: messages
        )
    }

    private static func fileIdentity(at url: URL) -> CleanupFileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return CleanupFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func allocatedSize(at url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
            )
            return Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
        } catch {
            return nil
        }
    }
}

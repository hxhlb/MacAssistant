import Foundation

public enum IpaPreflightSeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case blocker
}

public struct IpaPreflightFinding: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let severity: IpaPreflightSeverity
    public let code: String
    public let message: String

    public init(
        id: UUID = UUID(),
        severity: IpaPreflightSeverity,
        code: String,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
    }
}

public struct IpaTargetPreflight: Codable, Hashable, Sendable {
    public let itemID: UUID
    public let dylibName: String
    public let dylibSHA256: String
    public let targetRelativePath: String
    public let targetArchitectures: [String]
    public let dylibArchitectures: [String]
    public let loadPath: String
    public let embeddedRelativePath: String
}

public struct IpaPreflightReport: Codable, Hashable, Sendable {
    public let inputAppName: String
    public let bundleID: String
    public let targets: [IpaTargetPreflight]
    public let componentRemovals: [EmbeddedComponent]
    public let findings: [IpaPreflightFinding]

    public var hasBlockers: Bool {
        findings.contains { $0.severity == .blocker }
    }
}

public struct IpaArtifactAuditEntry: Codable, Hashable, Sendable {
    public let itemID: UUID
    public let targetRelativePath: String
    public let loadPath: String
    public let auditedSliceCount: Int
    public let loadKind: InjectionLoadKind
}

/// 一条「本机无法确认」的依赖。
///
/// 与「确认缺失」是两回事:本机静态分析既无法在越狱环境里核对 `deviceProvided`,
/// 也无法为 `unknown` 找到可靠依据,所以只能如实说「不确定」,交由设备验证——
/// 绝不因为不确定就当成已解析(假阴性),也不因为不确定就当成失败(假阳性)。
public struct IpaUnconfirmedDependency: Codable, Hashable, Sendable {
    /// 引用该依赖的 Mach-O 在 App 内的相对路径。
    public let referencedBy: String
    public let installPath: String
    public let fileName: String
    /// 只会是 .deviceProvided 或 .unknown;systemLibrary/appEmbedded/pluginProvided 属于已解析,不进此列。
    public let classification: DependencyClassification
    /// 结论依据(来自 DependencyClassifier),可直接展示给用户。
    public let evidence: String

    public init(
        referencedBy: String,
        installPath: String,
        fileName: String,
        classification: DependencyClassification,
        evidence: String
    ) {
        self.referencedBy = referencedBy
        self.installPath = installPath
        self.fileName = fileName
        self.classification = classification
        self.evidence = evidence
    }
}

public struct IpaArtifactAuditReport: Codable, Hashable, Sendable {
    public let payloadStructureValid: Bool
    public let entries: [IpaArtifactAuditEntry]
    /// 「确认缺失」的依赖:本机能明确判定其无法解析。本机静态分析通常无法证明设备上的缺失,
    /// 因此此列表多为空;保留它以承载真正可判定的硬缺失,并作为 passed 的失败依据。
    public let unresolvedDependencies: [String]
    /// 「本机无法确认」的依赖(deviceProvided / unknown)。这些不计入已解析,产出 warning,
    /// 但**不**使 passed 变 false——不确定不等于失败。UI 应据此提示「需在设备上验证」。
    public let unconfirmedDependencies: [IpaUnconfirmedDependency]
    public let signatureVerified: Bool?

    public init(
        payloadStructureValid: Bool,
        entries: [IpaArtifactAuditEntry],
        unresolvedDependencies: [String],
        unconfirmedDependencies: [IpaUnconfirmedDependency] = [],
        signatureVerified: Bool?
    ) {
        self.payloadStructureValid = payloadStructureValid
        self.entries = entries
        self.unresolvedDependencies = unresolvedDependencies
        self.unconfirmedDependencies = unconfirmedDependencies
        self.signatureVerified = signatureVerified
    }

    public var passed: Bool {
        payloadStructureValid && !entries.isEmpty
            && unresolvedDependencies.isEmpty && signatureVerified != false
    }
}

public struct MachOLoadCommandSnapshot: Codable, Hashable, Sendable {
    public let path: String
    public let weak: Bool

    public init(path: String, weak: Bool) {
        self.path = path
        self.weak = weak
    }

    /// 用于集合比对的稳定标识:弱引用与强引用视为不同的加载命令。
    public var identity: String { (weak ? "weak " : "") + path }
}

public struct MachOSliceSnapshot: Codable, Hashable, Sendable {
    public let index: Int
    public let loadCommands: [MachOLoadCommandSnapshot]

    public init(index: Int, loadCommands: [MachOLoadCommandSnapshot]) {
        self.index = index
        self.loadCommands = loadCommands
    }
}

/// 对单个 Mach-O 产物的一次「重新读取」快照。字段全部来自实际读盘,不含任何计划值。
public struct MachOArtifactSnapshot: Codable, Hashable, Sendable {
    public let relativePath: String
    public let sha256: String
    public let architectures: [String]
    public let slices: [MachOSliceSnapshot]
    public let dependencies: [String]
    public let rpaths: [String]
    public let signature: DylibSignatureState

    public init(
        relativePath: String,
        sha256: String,
        architectures: [String],
        slices: [MachOSliceSnapshot],
        dependencies: [String],
        rpaths: [String],
        signature: DylibSignatureState
    ) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.architectures = architectures
        self.slices = slices
        self.dependencies = dependencies
        self.rpaths = rpaths
        self.signature = signature
    }

    /// 全切片去重后的加载命令标识集合(弱/强区分)。
    public var loadCommandIdentities: Set<String> {
        Set(slices.flatMap { $0.loadCommands.map(\.identity) })
    }
}

public enum MachOArtifactChangeKind: String, Codable, Hashable, Sendable {
    case added
    case removed
    case modified
    case unchanged
}

/// 单个产物的前后对照。所有布尔/增删项都由 before 与 after 两次独立读取比对得出。
public struct MachOArtifactDiff: Codable, Hashable, Sendable {
    public let relativePath: String
    public let change: MachOArtifactChangeKind
    public let before: MachOArtifactSnapshot?
    public let after: MachOArtifactSnapshot?
    public let addedLoadCommands: [String]
    public let removedLoadCommands: [String]
    public let addedRPaths: [String]
    public let removedRPaths: [String]
    public let sha256Changed: Bool
    public let signatureChanged: Bool

    public init(
        relativePath: String,
        change: MachOArtifactChangeKind,
        before: MachOArtifactSnapshot?,
        after: MachOArtifactSnapshot?,
        addedLoadCommands: [String],
        removedLoadCommands: [String],
        addedRPaths: [String],
        removedRPaths: [String],
        sha256Changed: Bool,
        signatureChanged: Bool
    ) {
        self.relativePath = relativePath
        self.change = change
        self.before = before
        self.after = after
        self.addedLoadCommands = addedLoadCommands
        self.removedLoadCommands = removedLoadCommands
        self.addedRPaths = addedRPaths
        self.removedRPaths = removedRPaths
        self.sha256Changed = sha256Changed
        self.signatureChanged = signatureChanged
    }
}

/// 注入前后的独立复核报告。`before`/`after` 都是重新读盘的快照,`diffs` 是逐产物对照。
public struct IpaArtifactDiffReport: Codable, Hashable, Sendable {
    public let before: [MachOArtifactSnapshot]
    public let after: [MachOArtifactSnapshot]
    public let diffs: [MachOArtifactDiff]

    public init(
        before: [MachOArtifactSnapshot],
        after: [MachOArtifactSnapshot],
        diffs: [MachOArtifactDiff]
    ) {
        self.before = before
        self.after = after
        self.diffs = diffs
    }

    public var changedPaths: [String] {
        diffs.filter { $0.change != .unchanged }.map(\.relativePath)
    }

    public var hasChanges: Bool { diffs.contains { $0.change != .unchanged } }
}

public struct IpaInjectionExecutionResult: Sendable {
    public let outputURL: URL
    public let preflight: IpaPreflightReport
    public let audit: IpaArtifactAuditReport
    /// 注入前后独立重读产物得到的对照报告。用于向用户呈现「实际改了什么」,
    /// 而不是复述注入器自报的结果。
    public let diff: IpaArtifactDiffReport
    public let log: [String]
}

public enum IpaInjectionWorkflowError: LocalizedError {
    case preflight([IpaPreflightFinding])
    case targetNotFound(String)
    case pathEscapesApp(String)
    case resourceConflict(String)
    case unsupportedIcon(String)
    case auditFailed(String)
    case outputExists(String)

    public var errorDescription: String? {
        switch self {
        case let .preflight(findings):
            return L("ipaflow.error.preflight") + "\n" + findings
                .filter { $0.severity == .blocker }
                .map { "• \($0.message)" }
                .joined(separator: "\n")
        case let .targetNotFound(path): return L("ipaflow.error.targetNotFound", path)
        case let .pathEscapesApp(path): return L("ipaflow.error.pathEscapesApp", path)
        case let .resourceConflict(path): return L("ipaflow.error.resourceConflict", path)
        case let .unsupportedIcon(name): return L("ipaflow.error.unsupportedIcon", name)
        case let .auditFailed(reason): return L("ipaflow.error.auditFailed", reason)
        case let .outputExists(path): return L("ipaflow.error.outputExists", path)
        }
    }
}

public enum IpaInjectionWorkflow {
    private struct ResolvedInjection {
        let item: InjectionItem
        let targetURL: URL
        let targetRelativePath: String
        let embeddedURL: URL
        let embeddedRelativePath: String
        let loadPath: String
    }

    public static func preflight(_ plan: InjectionPlan) throws -> IpaPreflightReport {
        try preflight(plan.validated())
    }

    public static func preflight(_ plan: ValidatedInjectionPlan) throws -> IpaPreflightReport {
        switch plan.input {
        case let .ipa(url):
            let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "ipa-preflight")
            defer { try? FileManager.default.removeItem(at: work) }
            let extraction = work.appendingPathComponent("extract")
            try IpaService.unzip(url, to: extraction)
            try IpaService.validatePayloadStructure(in: extraction)
            let app = try IpaService.locateApp(in: extraction)
            return try preflight(plan, app: app)
        case let .app(url):
            try validateAppDirectory(url)
            return try preflight(plan, app: url)
        }
    }

    public static func execute(
        _ sourcePlan: InjectionPlan,
        outputURL: URL? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> IpaInjectionExecutionResult {
        try execute(sourcePlan.validated(), outputURL: outputURL, progress: progress)
    }

    public static func execute(
        _ plan: ValidatedInjectionPlan,
        outputURL: URL? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> IpaInjectionExecutionResult {
        var log: [String] = []
        func emit(_ line: String) {
            log.append(line)
            progress?(line)
        }
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "injection-plan")
        var didClearWork = false
        func clearWorkCache() {
            guard !didClearWork else { return }
            didClearWork = true
            try? FileManager.default.removeItem(at: work)
            emit(InjectionProgressLog.clearedCache())
        }
        defer { clearWorkCache() }

        let app: URL
        let archiveRoot: URL?
        switch plan.input {
        case let .ipa(input):
            let extraction = work.appendingPathComponent("extract")
            emit(InjectionProgressLog.unzipStart())
            try IpaService.unzip(input, to: extraction)
            emit(InjectionProgressLog.unzipProgress(100))
            try IpaService.validatePayloadStructure(in: extraction)
            app = try IpaService.locateApp(in: extraction)
            archiveRoot = extraction
            emit(InjectionProgressLog.unzipSucceeded())
        case let .app(input):
            try validateAppDirectory(input)
            let staged = work.appendingPathComponent(input.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: input, to: staged)
            app = staged
            archiveRoot = nil
            emit(InjectionProgressLog.appCopySucceeded())
        }

        let preflight = try preflight(plan, app: app)
        guard !preflight.hasBlockers else {
            throw IpaInjectionWorkflowError.preflight(preflight.findings)
        }

        let currentBundleID = ((try? IpaService.infoPlist(appBundle: app))?["CFBundleIdentifier"] as? String) ?? ""
        let metadata = plan.metadata.resolvingBundleID(current: currentBundleID)
        if metadata.randomizeBundleIDForPPQ, let rewritten = metadata.bundleID {
            emit(L("ipaflow.log.ppqBundleID", rewritten))
        }

        // 资源先落地，injectipa 也是先改包内文件再删组件。ElleKit 等框架必须在改依赖前就位。
        try applyResources(plan.resources, to: app, emit: emit)

        let mainExecutable = try mainExecutable(in: app)
        let resolved = try plan.items.map {
            try resolve($0, app: app, mainExecutable: mainExecutable)
        }
        let beforeSnapshot = try snapshotMachO(
            files: touchedMachOFiles(resolved: resolved, extras: []),
            in: app,
            detailed: false
        )
        // 与 injectipa 对齐：每个 dylib 拷贝 → 改依赖 → 注入，然后再删小组件 / 手表、改 plist。
        let rewritten = try embedAndInject(
            resolved,
            plan: plan,
            app: app,
            mainExecutable: mainExecutable,
            stripCodeSignature: plan.stripCodeSignatureIfNeeded,
            emit: emit
        )
        try applyComponentPolicy(plan.components, to: app, emit: emit)
        try applyMetadata(metadata, to: app, emit: emit)

        var signingLog: [String] = []
        switch plan.signing {
        case .none:
            break
        case .adHoc:
            _ = try SigningService.resignJailbreak(
                app: app,
                method: .codesignAdhoc,
                entitlements: nil,
                log: &signingLog
            )
        case .ldid:
            _ = try SigningService.resignJailbreak(
                app: app,
                method: .ldid,
                entitlements: nil,
                log: &signingLog
            )
        case let .realDevice(recipe):
            try SigningService.resignRealDeviceGraph(
                app: app,
                recipe: recipe,
                overrideBundleID: metadata.bundleID,
                log: &signingLog
            )
        case let .appleID(recipe):
            _ = try AppleIDSigningService.applyToApp(
                app,
                recipe: recipe,
                overrideBundleID: metadata.bundleID,
                log: &signingLog
            )
        }
        signingLog.forEach(emit)

        let stagedAudit = try audit(plan: plan, app: app)
        guard stagedAudit.passed else {
            throw IpaInjectionWorkflowError.auditFailed(stagedAudit.unresolvedDependencies.joined(separator: "\n"))
        }

        let output = try outputDestination(plan: plan, override: outputURL)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw IpaInjectionWorkflowError.outputExists(output.path)
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let finalAudit: IpaArtifactAuditReport
        var afterSnapshot: [MachOArtifactSnapshot] = []
        switch plan.input {
        case .ipa:
            guard let archiveRoot else {
                throw IpaInjectionWorkflowError.auditFailed(L("ipaflow.audit.missingStagingRoot"))
            }
            // 半成品落在可写的执行工作目录，而不是最终输出旁——源快照目录是 0o555。
            let temporary = stagingURL(for: output, in: work)
            defer { try? FileManager.default.removeItem(at: temporary) }
            emit(InjectionProgressLog.zipStart())
            let topItems = try FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)
            let zip = try ExternalTool.zip.run(
                // 注入产物以尽快交付/安装为主。`-1` 相比默认 deflate 明显缩短大型
                // 二进制的重压缩时间,代价是输出包会略大。
                ["-qry", "-1", "-X", temporary.path] + topItems,
                currentDirectory: archiveRoot
            )
            guard zip.succeeded else { throw IpaError.commandFailed(zip.combinedOutput) }
            emit(InjectionProgressLog.zipProgress(100))
            _ = try ArchiveSafety.validateZIP(at: temporary)

            // 暂存 App 已在压缩前逐切片审计;zip 成功后再校验中央目录和本地文件头即可。
            // 不再把刚生成的大型 IPA 全量解压第二遍——那会让「压缩完成」之后仍产生一轮
            // 与包体积等量的读写。after 仍从修改后的真实文件重读,不使用计划值。
            finalAudit = stagedAudit
            afterSnapshot = try snapshotMachO(
                files: touchedMachOFiles(resolved: resolved, extras: rewritten),
                in: app,
                detailed: false
            )
            try FileManager.default.moveItem(at: temporary, to: output)
            emit(InjectionProgressLog.zipSucceeded(output.path))
        case .app:
            let temporary = stagingURL(for: output, in: work)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: app, to: temporary)
            finalAudit = try audit(plan: plan, app: temporary)
            guard finalAudit.passed else {
                throw IpaInjectionWorkflowError.auditFailed(finalAudit.unresolvedDependencies.joined(separator: "\n"))
            }
            afterSnapshot = try snapshotMachO(
                files: touchedMachOFiles(resolved: resolved, extras: rewritten),
                in: app,
                detailed: false
            )
            try FileManager.default.moveItem(at: temporary, to: output)
            emit(InjectionProgressLog.appPackaged(output.path))
        }
        clearWorkCache()
        return IpaInjectionExecutionResult(
            outputURL: output,
            preflight: preflight,
            audit: finalAudit,
            diff: diff(before: beforeSnapshot, after: afterSnapshot),
            log: log
        )
    }

    private static func preflight(
        _ plan: ValidatedInjectionPlan,
        app: URL
    ) throws -> IpaPreflightReport {
        let plist = try IpaService.infoPlist(appBundle: app)
        let currentBundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let effectiveBundleID = plan.metadata.bundleID ?? currentBundleID
        let main = try mainExecutable(in: app)
        var findings: [IpaPreflightFinding] = []
        var targets: [IpaTargetPreflight] = []
        let resolved = try plan.items.map { try resolve($0, app: app, mainExecutable: main) }
        let appFileNames = Set(
            FileSystemHelper.allFiles(in: app, where: { !FileSystemHelper.isDirectory($0) })
                .map { $0.lastPathComponent.lowercased() }
        ).union(
            plan.resources.flatMap { resource in
                FileSystemHelper.isDirectory(resource.sourceURL)
                    ? FileSystemHelper.allFiles(in: resource.sourceURL, where: { !FileSystemHelper.isDirectory($0) })
                    : [resource.sourceURL]
            }.map { $0.lastPathComponent.lowercased() }
        )

        var contentHashes: [String: String] = [:]
        var installNames: [String: String] = [:]
        var providedNames = Set(plan.items.map { $0.dylibURL.lastPathComponent.lowercased() })
        if plan.rewriteJailbreakDependencies,
           JailbreakDependencyRewriter.mode(app: app, resources: plan.resources) == .bundledStub {
            providedNames.insert(JailbreakDependencyRewriter.stubFileName.lowercased())
        }
        let context = dependencyContext(providedNames: providedNames, appFileNames: appFileNames)
        for entry in resolved {
            guard FileManager.default.fileExists(atPath: entry.item.dylibURL.path) else {
                findings.append(.init(
                    severity: .blocker,
                    code: "dylib.missing",
                    message: L("ipaflow.finding.dylibMissing", entry.item.dylibURL.path)
                ))
                continue
            }
            let dylib = try DylibService.analyze(fileAt: entry.item.dylibURL)
            let target = try DylibService.analyze(fileAt: entry.targetURL)
            if target.isEncrypted {
                findings.append(.init(
                    severity: .blocker,
                    code: "target.cryptid",
                    message: L("ipaflow.finding.targetCryptid", entry.targetRelativePath)
                ))
            }
            if dylib.isEncrypted {
                findings.append(.init(
                    severity: .blocker,
                    code: "dylib.cryptid",
                    message: L("ipaflow.finding.dylibCryptid", entry.item.dylibURL.lastPathComponent)
                ))
            }
            let missing = Set(target.architectures).subtracting(dylib.architectures)
            if !missing.isEmpty {
                findings.append(.init(
                    severity: .blocker,
                    code: "architecture.mismatch",
                    message: L(
                        "ipaflow.finding.architectureMismatch",
                        entry.item.dylibURL.lastPathComponent,
                        missing.sorted().joined(separator: ",")
                    )
                ))
            }
            if target.isArm64e && !dylib.architectures.contains("arm64e") {
                findings.append(.init(
                    severity: .blocker,
                    code: "architecture.arm64e",
                    message: L("ipaflow.finding.arm64e", entry.targetRelativePath)
                ))
            }
            if target.hasSwift || target.hasChainedFixups || target.isArm64e {
                findings.append(.init(
                    severity: .warning,
                    code: "target.modern-runtime",
                    message: L("ipaflow.finding.modernRuntime", entry.targetRelativePath)
                ))
            }

            let inspections = try DylibInjector.inspectLoadCommands(fileAt: entry.targetURL)
            let existingSlices = inspections.filter {
                $0.commands.contains(where: { $0.path == entry.loadPath })
            }.count
            let existingKindsMatch = inspections.allSatisfy { slice in
                guard let command = slice.commands.first(where: { $0.path == entry.loadPath }) else {
                    return false
                }
                return command.weak == (entry.item.loadKind == .weak)
            }
            if existingSlices > 0 {
                switch entry.item.existingCommandPolicy {
                case .fail:
                    findings.append(.init(
                        severity: .blocker,
                        code: "load.duplicate",
                        message: L("ipaflow.finding.loadDuplicate", entry.targetRelativePath, entry.loadPath)
                    ))
                case .skip where existingSlices != inspections.count:
                    findings.append(.init(
                        severity: .blocker,
                        code: "load.partial",
                        message: L("ipaflow.finding.loadPartial", entry.loadPath)
                    ))
                case .skip where !existingKindsMatch:
                    findings.append(.init(
                        severity: .blocker,
                        code: "load.kind-mismatch",
                        message: L("ipaflow.finding.loadKindMismatch", entry.loadPath)
                    ))
                case .skip:
                    findings.append(.init(
                        severity: .info,
                        code: "load.skip",
                        message: L("ipaflow.finding.loadSkip", entry.loadPath)
                    ))
                case .replace:
                    findings.append(.init(
                        severity: .warning,
                        code: "load.replace",
                        message: L("ipaflow.finding.loadReplace", entry.loadPath)
                    ))
                }
            }

            if let previous = contentHashes[dylib.sha256],
               previous != entry.item.dylibURL.path {
                findings.append(.init(
                    severity: .warning,
                    code: "dylib.same-content",
                    message: L("ipaflow.finding.sameContent", entry.item.dylibURL.lastPathComponent)
                ))
            } else {
                contentHashes[dylib.sha256] = entry.item.dylibURL.path
            }
            if let installName = dylib.installName {
                if let hash = installNames[installName], hash != dylib.sha256 {
                    findings.append(.init(
                        severity: .blocker,
                        code: "dylib.install-name-conflict",
                        message: L("ipaflow.finding.installNameConflict", installName)
                    ))
                } else {
                    installNames[installName] = dylib.sha256
                }
            }
            for dependency in unconfirmedDependencies(of: dylib, context: context) {
                findings.append(.init(
                    severity: .warning,
                    code: "dependency.unresolved",
                    message: L(
                        "ipaflow.finding.dependencyUnconfirmed",
                        entry.item.dylibURL.lastPathComponent,
                        dependency.installPath,
                        dependency.evidence
                    )
                ))
            }
            if FileManager.default.fileExists(atPath: entry.embeddedURL.path) {
                let existingHash = try? DylibService.sha256(fileAt: entry.embeddedURL)
                if existingHash != dylib.sha256 {
                    findings.append(.init(
                        severity: entry.item.existingCommandPolicy == .replace ? .warning : .blocker,
                        code: "embed.conflict",
                        message: L("ipaflow.finding.embedConflict", entry.embeddedRelativePath)
                    ))
                }
            }
            targets.append(
                IpaTargetPreflight(
                    itemID: entry.item.id,
                    dylibName: entry.item.dylibURL.lastPathComponent,
                    dylibSHA256: dylib.sha256,
                    targetRelativePath: entry.targetRelativePath,
                    targetArchitectures: target.architectures,
                    dylibArchitectures: dylib.architectures,
                    loadPath: entry.loadPath,
                    embeddedRelativePath: entry.embeddedRelativePath
                )
            )
        }

        for resource in plan.resources {
            let sourceFiles = FileSystemHelper.isDirectory(resource.sourceURL)
                ? FileSystemHelper.allFiles(in: resource.sourceURL, where: { !FileSystemHelper.isDirectory($0) })
                : [resource.sourceURL]
            for file in sourceFiles where MachOIdentifier.isMachO(fileAt: file) {
                let analysis = try DylibService.analyze(fileAt: file)
                for dependency in unconfirmedDependencies(of: analysis, context: context) {
                    findings.append(.init(
                        severity: .warning,
                        code: "resource.dependency.unresolved",
                        message: L(
                            "ipaflow.finding.dependencyUnconfirmed",
                            file.lastPathComponent,
                            dependency.installPath,
                            dependency.evidence
                        )
                    ))
                }
            }
        }

        let componentRemovals = try InjectionTargetDiscovery.components(in: app).filter { component in
            switch component.kind {
            case .watch: return plan.components.watch == .remove
            case .appExtension: return plan.components.plugIns == .remove
            case .appClip: return plan.components.appClips == .remove
            }
        }

        var resourceKeys = Set<String>()
        for resource in plan.resources {
            let key = resource.destination.rawValue.precomposedStringWithCanonicalMapping.lowercased()
            if !resourceKeys.insert(key).inserted {
                findings.append(.init(
                    severity: .blocker,
                    code: "resource.duplicate",
                    message: L("ipaflow.finding.resourceDuplicate", resource.destination.rawValue)
                ))
            }
            if !FileManager.default.fileExists(atPath: resource.sourceURL.path) {
                findings.append(.init(
                    severity: .blocker,
                    code: "resource.missing",
                    message: L("ipaflow.finding.resourceMissing", resource.sourceURL.path)
                ))
            }
            let destination = try containedURL(resource.destination, in: app)
            let destinationRelative = relativePath(destination, under: app) ?? ""
            let removedByPolicy = componentRemovals.contains {
                destinationRelative == $0.relativePath
                    || destinationRelative.hasPrefix($0.relativePath + "/")
            }
            if removedByPolicy {
                findings.append(.init(
                    severity: .blocker,
                    code: "resource.removed-component",
                    message: L("ipaflow.finding.resourceRemovedComponent", resource.destination.rawValue)
                ))
            }
            if FileManager.default.fileExists(atPath: destination.path) && !removedByPolicy {
                findings.append(.init(
                    severity: resource.replaceExisting ? .warning : .blocker,
                    code: resource.replaceExisting ? "resource.replace" : "resource.conflict",
                    message: resource.replaceExisting
                        ? L("ipaflow.finding.resourceReplace", resource.destination.rawValue)
                        : L("ipaflow.finding.resourceConflict", resource.destination.rawValue)
                ))
            }
        }

        if !plan.metadata.iconFiles.isEmpty {
            for icon in plan.metadata.iconFiles {
                if !["png", "icns"].contains(icon.pathExtension.lowercased()) {
                    findings.append(.init(
                        severity: .blocker,
                        code: "icon.unsupported",
                        message: L("ipaflow.finding.iconUnsupported", icon.lastPathComponent)
                    ))
                }
            }
        }

        if case let .realDevice(recipe) = plan.signing {
            if IpaZsignSigner.isIOSAppBundle(app) {
                if !ExternalTool.zsign.isAvailable {
                    findings.append(.init(
                        severity: .blocker,
                        code: "signing.zsign-missing",
                        message: L("ipaflow.finding.zsignMissing")
                    ))
                }
                let provision = IpaZsignSigner.primaryProvision(
                    profilesByBundleID: recipe.profilesByBundleID,
                    preferring: plan.metadata.bundleID
                )
                if provision == nil {
                    findings.append(.init(
                        severity: .blocker,
                        code: "signing.profile-missing",
                        message: L("ipaflow.finding.zsignProvisionMissing")
                    ))
                } else if let provision {
                    do {
                        let profile = try SigningService.readProfile(at: provision)
                        try SigningService.validateZsignProfile(
                            profile,
                            identityName: recipe.identityName
                        )
                    } catch {
                        findings.append(.init(
                            severity: .blocker,
                            code: "signing.profile-invalid",
                            message: L(
                                "ipaflow.finding.profileInvalid",
                                provision.lastPathComponent,
                                error.localizedDescription
                            )
                        ))
                    }
                }
            } else {
                let missing = try SigningService.missingProfileBundleIDs(
                    in: app,
                    profilesByBundleID: recipe.profilesByBundleID,
                    overridingRootBundleID: plan.metadata.bundleID,
                    excludingRelativePaths: Set(componentRemovals.map(\.relativePath))
                )
                if !missing.isEmpty {
                    findings.append(.init(
                        severity: .blocker,
                        code: "signing.profile-missing",
                        message: L("ipaflow.finding.profileMissing", missing.joined(separator: ","))
                    ))
                }
                for (bundleID, profileURL) in recipe.profilesByBundleID {
                    do {
                        let profile = try SigningService.readProfile(at: profileURL)
                        try SigningService.validateProfile(
                            profile,
                            identityName: recipe.identityName,
                            bundleID: bundleID
                        )
                    } catch {
                        findings.append(.init(
                            severity: .blocker,
                            code: "signing.profile-invalid",
                            message: L("ipaflow.finding.profileInvalid", bundleID, error.localizedDescription)
                        ))
                    }
                }
            }
        } else if plan.metadata.bundleID != nil {
            findings.append(.init(
                severity: .warning,
                code: "metadata.bundle-id-local",
                message: L("ipaflow.finding.bundleIDLocal")
            ))
        }

        return IpaPreflightReport(
            inputAppName: app.lastPathComponent,
            bundleID: effectiveBundleID,
            targets: targets,
            componentRemovals: componentRemovals,
            findings: findings
        )
    }

    private static func mainExecutable(in app: URL) throws -> URL {
        let plist = try IpaService.infoPlist(appBundle: app)
        let name = (plist["CFBundleExecutable"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let macOSDirectory = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let executable = FileSystemHelper.isDirectory(macOSDirectory)
            ? macOSDirectory.appendingPathComponent(name)
            : app.appendingPathComponent(name)
        guard MachOIdentifier.isMachO(fileAt: executable) else { throw IpaError.executableNotFound }
        return executable
    }

    private static func resolve(
        _ item: InjectionItem,
        app: URL,
        mainExecutable: URL
    ) throws -> ResolvedInjection {
        let target: URL
        switch item.target {
        case .mainExecutable:
            target = mainExecutable
        case .preferredFrameworkHost:
            guard let preferred = PreferredInjectionHost.url(in: app) else {
                throw IpaInjectionWorkflowError.targetNotFound("ProtobufLite3 / ProtobufLite2 / ProtobufLite")
            }
            target = preferred
        case let .namedFrameworkHost(name):
            guard let choice = PreferredInjectionHost.Choice(rawValue: name),
                  choice.frameworkName != nil,
                  let preferred = PreferredInjectionHost.url(in: app, preferring: choice) else {
                throw IpaInjectionWorkflowError.targetNotFound(name)
            }
            target = preferred
        case let .relativeMachO(path):
            target = try containedURL(path, in: app)
        }
        guard MachOIdentifier.isMachO(fileAt: target) else {
            throw IpaInjectionWorkflowError.targetNotFound(relativePath(target, under: app) ?? target.path)
        }
        guard let bundle = owningExecutableBundle(for: target, app: app) else {
            throw IpaInjectionWorkflowError.pathEscapesApp(target.path)
        }
        let macOSContents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let frameworks = (FileSystemHelper.isDirectory(macOSContents) ? macOSContents : bundle)
            .appendingPathComponent("Frameworks", isDirectory: true)
        let embedded = frameworks.appendingPathComponent(item.dylibURL.lastPathComponent)
        let targetRelative = relativePath(target, under: app) ?? target.lastPathComponent
        let embeddedRelative = relativePath(embedded, under: app) ?? embedded.lastPathComponent
        let loadPath: String
        if let custom = item.customLoadPath {
            loadPath = custom
        } else if target.deletingLastPathComponent().standardizedFileURL == bundle.standardizedFileURL {
            loadPath = "@executable_path/Frameworks/\(item.dylibURL.lastPathComponent)"
        } else {
            let relative = relativePath(from: target.deletingLastPathComponent(), to: embedded)
            loadPath = "@loader_path/\(relative)"
        }
        if item.existingCommandPolicy == .replace, item.customLoadPath == nil,
           let old = try? existingVersionedDylib(
               target: target,
               bundle: bundle,
               newName: item.dylibURL.lastPathComponent
           ) {
            return ResolvedInjection(
                item: item,
                targetURL: target,
                targetRelativePath: targetRelative,
                embeddedURL: old.url,
                embeddedRelativePath: relativePath(old.url, under: app) ?? old.url.lastPathComponent,
                loadPath: old.loadPath
            )
        }
        return ResolvedInjection(
            item: item,
            targetURL: target,
            targetRelativePath: targetRelative,
            embeddedURL: embedded,
            embeddedRelativePath: embeddedRelative,
            loadPath: loadPath
        )
    }

    private static func existingVersionedDylib(
        target: URL,
        bundle: URL,
        newName: String
    ) throws -> (url: URL, loadPath: String)? {
        let identity = dylibIdentity(newName)
        guard !identity.isEmpty else { return nil }
        let commands = try DylibInjector.inspectLoadCommands(fileAt: target)
            .flatMap(\.commands)
        let frameworks = bundle.appendingPathComponent("Frameworks", isDirectory: true)
        let candidates = FileSystemHelper.allFiles(in: frameworks) {
            MachOIdentifier.isMachO(fileAt: $0)
                && dylibIdentity($0.lastPathComponent) == identity
                && $0.lastPathComponent != newName
        }
        for command in commands {
            let name = (command.path as NSString).lastPathComponent
            guard let old = candidates.first(where: { $0.lastPathComponent == name }) else { continue }
            return (old, command.path)
        }
        return nil
    }

    private static func dylibIdentity(_ name: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return stem
            .replacingOccurrences(
                of: #"(?i)([-_.]?\d+){2,}([_-]\d+)*$"#,
                with: "",
                options: .regularExpression
            )
            .lowercased()
    }

    /// injectipa 顺序：拷贝 → 有越狱依赖就改 → 注入。
    @discardableResult
    private static func embedAndInject(
        _ entries: [ResolvedInjection],
        plan: ValidatedInjectionPlan,
        app: URL,
        mainExecutable: URL,
        stripCodeSignature: Bool,
        emit: (String) -> Void
    ) throws -> [URL] {
        var published: [String: String] = [:]
        var rewritten: [URL] = []
        let mode = plan.rewriteJailbreakDependencies
            ? JailbreakDependencyRewriter.mode(app: app, resources: plan.resources)
            : nil
        var didEmbedStub = false
        for entry in entries {
            let name = entry.item.dylibURL.lastPathComponent
            try embedDylib(entry, published: &published, emit: emit)
            if let mode,
               FileManager.default.fileExists(atPath: entry.embeddedURL.path),
               !JailbreakDependencyRewriter.isSubstrateRuntimeFile(entry.embeddedURL) {
                if !didEmbedStub,
                   mode == .bundledStub,
                   fileNeedsSubstrateStub(entry.embeddedURL) {
                    try embedBundledSubstrateStub(in: app, emit: emit)
                    didEmbedStub = true
                    let stub = frameworksDirectory(in: app)
                        .appendingPathComponent(JailbreakDependencyRewriter.stubFileName)
                    if FileManager.default.fileExists(atPath: stub.path) {
                        rewritten.append(stub)
                    }
                }
                if try rewriteJailbreakDependencies(
                    of: entry.embeddedURL,
                    app: app,
                    mainExecutable: mainExecutable,
                    mode: mode,
                    emit: emit
                ) {
                    rewritten.append(entry.embeddedURL)
                }
            }
            emit(InjectionProgressLog.injectStart(name))
            _ = try DylibInjector.inject(
                requests: [
                    DylibInjectionRequest(
                        dylibPath: entry.loadPath,
                        weak: entry.item.loadKind == .weak,
                        existingPolicy: entry.item.existingCommandPolicy
                    )
                ],
                intoFileAt: entry.targetURL,
                stripCodeSignature: stripCodeSignature
            )
            emit(InjectionProgressLog.injectSucceeded(name))
        }
        return rewritten
    }

    private static func fileNeedsSubstrateStub(_ file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path),
              !JailbreakDependencyRewriter.isSubstrateRuntimeFile(file) else { return false }
        let paths = (try? DylibService.loadDependencyPaths(fileAt: file)) ?? []
        return paths.contains(where: JailbreakDependencyRewriter.isCydiaSubstrate)
    }

    private static func embedDylib(
        _ entry: ResolvedInjection,
        published: inout [String: String],
        emit: (String) -> Void
    ) throws {
        let name = entry.item.dylibURL.lastPathComponent
        let sourceHash = try DylibService.sha256(fileAt: entry.item.dylibURL)
        if let existing = published[entry.embeddedURL.path] {
            guard existing == sourceHash else {
                throw IpaInjectionWorkflowError.resourceConflict(entry.embeddedRelativePath)
            }
            return
        }
        published[entry.embeddedURL.path] = sourceHash
        if FileManager.default.fileExists(atPath: entry.embeddedURL.path) {
            if try DylibService.sha256(fileAt: entry.embeddedURL) != sourceHash {
                guard entry.item.existingCommandPolicy == .replace else {
                    throw IpaInjectionWorkflowError.resourceConflict(entry.embeddedRelativePath)
                }
                try FileManager.default.removeItem(at: entry.embeddedURL)
                try FileManager.default.copyItem(at: entry.item.dylibURL, to: entry.embeddedURL)
                emit(InjectionProgressLog.copyDylibSucceeded(name))
            }
            return
        }
        try FileManager.default.createDirectory(
            at: entry.embeddedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: entry.item.dylibURL, to: entry.embeddedURL)
        emit(InjectionProgressLog.copyDylibSucceeded(name))
    }

    private static func embedBundledSubstrateStub(in app: URL, emit: (String) -> Void) throws {
        guard let source = JailbreakDependencyRewriter.bundledStubURL() else {
            throw IpaInjectionWorkflowError.auditFailed(L("ipaflow.error.missingSubstrateStub"))
        }
        let destination = frameworksDirectory(in: app)
            .appendingPathComponent(JailbreakDependencyRewriter.stubFileName)
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
        _ = emit
    }

    @discardableResult
    private static func rewriteJailbreakDependencies(
        of file: URL,
        app: URL,
        mainExecutable: URL,
        mode: JailbreakDependencyRewriter.SubstrateMode,
        emit: (String) -> Void
    ) throws -> Bool {
        let paths = try DylibService.loadDependencyPaths(fileAt: file)
        let changes = JailbreakDependencyRewriter.planRewrites(
            for: paths,
            binary: file,
            app: app,
            mainExecutable: mainExecutable,
            mode: mode
        )
        guard !changes.isEmpty else { return false }
        let name = file.lastPathComponent
        emit(InjectionProgressLog.discoveredDependencies(name))
        for change in changes {
            let rewrite = try DylibService.changeDependency(
                from: change.from,
                to: change.to,
                fileAt: file
            )
            guard rewrite.succeeded else {
                throw IpaInjectionWorkflowError.auditFailed(
                    L("tweak.error.rewriteFailed", change.from, change.to, rewrite.combinedOutput)
                )
            }
        }
        if changes.contains(where: { $0.to.hasPrefix("@rpath/") }) {
            let rpath = JailbreakDependencyRewriter.rpathNeededToResolveNativeFramework(
                for: file,
                app: app,
                mainExecutable: mainExecutable
            )
            _ = try DylibService.ensureRPath(rpath, fileAt: file)
        }
        emit(InjectionProgressLog.rewrittenDependencies(name))
        return true
    }

    private static func frameworksDirectory(in app: URL) -> URL {
        let macOSContents = app.appendingPathComponent("Contents", isDirectory: true)
        let root = FileSystemHelper.isDirectory(app.appendingPathComponent("Contents/MacOS", isDirectory: true))
            ? macOSContents
            : app
        return root.appendingPathComponent("Frameworks", isDirectory: true)
    }

    private static func applyResources(
        _ resources: [InjectionResource],
        to app: URL,
        emit: (String) -> Void
    ) throws {
        for resource in resources {
            let destination = try containedURL(resource.destination, in: app)
            if FileManager.default.fileExists(atPath: destination.path) {
                if resource.replaceExisting {
                    try FileManager.default.removeItem(at: destination)
                    emit(L("ipaflow.log.resourceReplaced", resource.destination.rawValue))
                } else {
                    throw IpaInjectionWorkflowError.resourceConflict(resource.destination.rawValue)
                }
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: resource.sourceURL, to: destination)
            emit(L("ipaflow.log.resourceAdded", resource.destination.rawValue))
        }
    }

    private static func applyMetadata(
        _ changes: InjectionMetadataChanges,
        to app: URL,
        emit: (String) -> Void
    ) throws {
        let plistURL = IpaService.infoPlistURL(appBundle: app)
        let data = try Data(contentsOf: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw IpaError.invalidPayload(L("ipaflow.error.infoPlistRootNotDictionary"))
        }
        if let bundleID = changes.bundleID {
            let changed = try SigningService.rewriteBundleIDGraph(in: app, rootBundleID: bundleID)
            emit(L("ipaflow.log.bundleIDUpdated"))
            if !changed.isEmpty {
                emit(L("ipaflow.log.componentBundleIDsUpdated", changed.count))
            }
        }
        let applied = InfoPlistMetadataApplier.apply(changes, to: &plist)
        if applied.contains("displayName") { emit(L("ipaflow.log.displayNameUpdated")) }
        if applied.contains("shortVersion") { emit(L("ipaflow.log.shortVersionUpdated")) }
        if applied.contains("buildVersion") { emit(L("ipaflow.log.buildVersionUpdated")) }
        if applied.contains("minimumOSVersion") { emit(L("ipaflow.log.minimumOSUpdated")) }
        if applied.contains("fileSharing") { emit(InjectionProgressLog.fileSharingEnabled()) }
        if applied.contains("voip") { emit(L("ipaflow.log.voipRemoved")) }
        if applied.contains("urlSchemes") { emit(L("ipaflow.log.urlSchemesRemoved")) }
        if !changes.iconFiles.isEmpty {
            var names: [String] = []
            for icon in changes.iconFiles {
                guard ["png", "icns"].contains(icon.pathExtension.lowercased()) else {
                    throw IpaInjectionWorkflowError.unsupportedIcon(icon.lastPathComponent)
                }
                let destination = app.appendingPathComponent(icon.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: icon, to: destination)
                names.append(icon.lastPathComponent)
            }
            registerLooseIcons(names, in: &plist)
            emit(L("ipaflow.log.iconsCopied", names.count))
        }
        if changes.repairWhiteIcon {
            let removals = try AssetCatalogIconRepair.repair(in: app)
            for removal in removals {
                emit(
                    InjectionProgressLog.assetsCarRemoved(
                        appName: app.lastPathComponent,
                        rendition: removal.renditionName
                    )
                )
            }
            let loose = AppIconRepair.pngBasenames(in: app)
            AppIconRepair.apply(to: &plist, extraFiles: loose)
            if removals.isEmpty {
                emit(L("ipaflow.log.whiteIconRepaired"))
            }
        }
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        ).write(to: plistURL, options: .atomic)
    }

    private static func registerLooseIcons(_ names: [String], in plist: inout [String: Any]) {
        plist["CFBundleIconFiles"] = names
        plist.removeValue(forKey: "CFBundleIconName")
        for key in plist.keys where key == "CFBundleIcons" || key.hasPrefix("CFBundleIcons~") {
            guard var icons = plist[key] as? [String: Any] else { continue }
            var primary = icons["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
            primary["CFBundleIconFiles"] = names
            primary.removeValue(forKey: "CFBundleIconName")
            icons["CFBundlePrimaryIcon"] = primary
            plist[key] = icons
        }
    }

    private static func applyComponentPolicy(
        _ policy: InjectionComponentPolicy,
        to app: URL,
        emit: (String) -> Void
    ) throws {
        let mappings: [(ComponentDisposition, [String], String)] = [
            (policy.plugIns, ["PlugIns"], InjectionProgressLog.removedPlugIns()),
            (policy.watch, ["Watch", "WatchPlaceholder"], InjectionProgressLog.removedWatch()),
            (policy.appClips, ["AppClips"], InjectionProgressLog.removedAppClips())
        ]
        for (disposition, names, line) in mappings where disposition == .remove {
            guard policy.destructiveRemovalConfirmed else {
                throw InjectionPlanError.validation([L("ipaflow.error.removalUnconfirmed")])
            }
            var removed = false
            for name in names {
                let target = app.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                    removed = true
                }
            }
            if removed {
                emit(line)
            }
        }
    }

    /// 只核对计划里选中的注入目标是否带上对应 dylib。
    /// 不扫 Frameworks / PlugIns / Watch / App Clip 里未被选中的 Mach-O。
    private static func audit(
        plan: ValidatedInjectionPlan,
        app: URL
    ) throws -> IpaArtifactAuditReport {
        let main = try mainExecutable(in: app)
        let resolved = try plan.items.map { try resolve($0, app: app, mainExecutable: main) }
        var entries: [IpaArtifactAuditEntry] = []
        var unconfirmed: [IpaUnconfirmedDependency] = []
        let appFileNames = Set(
            FileSystemHelper.allFiles(in: app, where: { !FileSystemHelper.isDirectory($0) })
                .map { $0.lastPathComponent.lowercased() }
        )
        let providedNames = Set(resolved.map { $0.embeddedURL.lastPathComponent.lowercased() })
        let context = dependencyContext(providedNames: providedNames, appFileNames: appFileNames)
        for entry in resolved {
            guard FileManager.default.fileExists(atPath: entry.embeddedURL.path) else {
                throw IpaInjectionWorkflowError.auditFailed(
                    L("ipaflow.audit.missingEmbedded", entry.embeddedRelativePath)
                )
            }
            let slices = try DylibInjector.inspectLoadCommands(fileAt: entry.targetURL)
            for slice in slices {
                guard let command = slice.commands.first(where: { $0.path == entry.loadPath }) else {
                    throw IpaInjectionWorkflowError.auditFailed(
                        L(
                            "ipaflow.audit.sliceMissingLoad",
                            entry.targetRelativePath,
                            slice.index,
                            entry.loadPath
                        )
                    )
                }
                guard command.weak == (entry.item.loadKind == .weak) else {
                    throw IpaInjectionWorkflowError.auditFailed(
                        L("ipaflow.audit.sliceKindMismatch", entry.targetRelativePath, slice.index)
                    )
                }
            }
            let analysis = try DylibService.analyze(fileAt: entry.embeddedURL)
            unconfirmed.append(contentsOf: unconfirmedDependencies(of: analysis, context: context).map {
                IpaUnconfirmedDependency(
                    referencedBy: entry.embeddedRelativePath,
                    installPath: $0.installPath,
                    fileName: $0.fileName,
                    classification: $0.classification,
                    evidence: $0.evidence
                )
            })
            entries.append(
                IpaArtifactAuditEntry(
                    itemID: entry.item.id,
                    targetRelativePath: entry.targetRelativePath,
                    loadPath: entry.loadPath,
                    auditedSliceCount: slices.count,
                    loadKind: entry.item.loadKind
                )
            )
        }
        for resource in plan.resources {
            let destination = try containedURL(resource.destination, in: app)
            let files = FileSystemHelper.isDirectory(destination)
                ? FileSystemHelper.allFiles(in: destination, where: { !FileSystemHelper.isDirectory($0) })
                : [destination]
            for file in files where MachOIdentifier.isMachO(fileAt: file) {
                let analysis = try DylibService.analyze(fileAt: file)
                let referencedBy = relativePath(file, under: app) ?? file.lastPathComponent
                unconfirmed.append(contentsOf: unconfirmedDependencies(of: analysis, context: context).map {
                    IpaUnconfirmedDependency(
                        referencedBy: referencedBy,
                        installPath: $0.installPath,
                        fileName: $0.fileName,
                        classification: $0.classification,
                        evidence: $0.evidence
                    )
                })
            }
        }
        let signatureVerified: Bool?
        switch plan.signing {
        case .none, .ldid:
            signatureVerified = nil
        case .adHoc, .realDevice, .appleID:
            let verify = try ExternalTool.codesign.run(["--verify", "--strict", "--verbose=4", app.path])
            signatureVerified = verify.succeeded
        }
        // 本机静态分析无法「确认缺失」,因此 unresolvedDependencies 留空;不确定的一律进
        // unconfirmedDependencies,不冒充已解析,也不当作失败。
        let dedupedUnconfirmed = Array(
            Dictionary(unconfirmed.map { ("\($0.referencedBy)|\($0.installPath)", $0) }) { first, _ in first }
                .values
        ).sorted { ($0.referencedBy, $0.installPath) < ($1.referencedBy, $1.installPath) }
        return IpaArtifactAuditReport(
            payloadStructureValid: true,
            entries: entries,
            unresolvedDependencies: [],
            unconfirmedDependencies: dedupedUnconfirmed,
            signatureVerified: signatureVerified
        )
    }

    // MARK: 注入后独立复核(WI3)

    /// 独立重新读取一个 IPA/App 内全部 Mach-O 的状态。所有字段都来自实际读盘。
    public static func snapshot(_ input: InjectionInput) throws -> [MachOArtifactSnapshot] {
        let work = try FileSystemHelper.makeTemporaryDirectory(prefix: "artifact-snapshot")
        defer { try? FileManager.default.removeItem(at: work) }
        let app: URL
        switch input {
        case let .ipa(url):
            let extraction = work.appendingPathComponent("extract", isDirectory: true)
            try IpaService.unzip(url, to: extraction)
            try IpaService.validatePayloadStructure(in: extraction)
            app = try IpaService.locateApp(in: extraction)
        case let .app(url):
            try validateAppDirectory(url)
            app = url
        }
        return try snapshotMachO(in: app)
    }

    /// 对原始输入与产物各做一次独立读取,给出前后对照。diff 完全由两次读取比对得出。
    public static func auditDiff(
        original: InjectionInput,
        produced: InjectionInput
    ) throws -> IpaArtifactDiffReport {
        let before = try snapshot(original)
        let after = try snapshot(produced)
        return diff(before: before, after: after)
    }

    /// 逐产物比对两份快照。added/removed/modified 由 relativePath 对齐后逐字段比较得出。
    public static func diff(
        before: [MachOArtifactSnapshot],
        after: [MachOArtifactSnapshot]
    ) -> IpaArtifactDiffReport {
        let beforeByPath = Dictionary(before.map { ($0.relativePath, $0) }) { first, _ in first }
        let afterByPath = Dictionary(after.map { ($0.relativePath, $0) }) { first, _ in first }
        let paths = Set(beforeByPath.keys).union(afterByPath.keys).sorted()
        let diffs = paths.map { path -> MachOArtifactDiff in
            let old = beforeByPath[path]
            let new = afterByPath[path]
            let oldLoads = old?.loadCommandIdentities ?? []
            let newLoads = new?.loadCommandIdentities ?? []
            let oldRPaths = Set(old?.rpaths ?? [])
            let newRPaths = Set(new?.rpaths ?? [])
            let sha256Changed = (old?.sha256 != new?.sha256)
            let signatureChanged = (old?.signature != new?.signature)

            let change: MachOArtifactChangeKind
            if old == nil {
                change = .added
            } else if new == nil {
                change = .removed
            } else if old == new {
                change = .unchanged
            } else {
                change = .modified
            }

            return MachOArtifactDiff(
                relativePath: path,
                change: change,
                before: old,
                after: new,
                addedLoadCommands: newLoads.subtracting(oldLoads).sorted(),
                removedLoadCommands: oldLoads.subtracting(newLoads).sorted(),
                addedRPaths: newRPaths.subtracting(oldRPaths).sorted(),
                removedRPaths: oldRPaths.subtracting(newRPaths).sorted(),
                sha256Changed: sha256Changed && old != nil && new != nil,
                signatureChanged: signatureChanged && old != nil && new != nil
            )
        }
        return IpaArtifactDiffReport(before: before, after: after, diffs: diffs)
    }

    private static func touchedMachOFiles(resolved: [ResolvedInjection], extras: [URL]) -> [URL] {
        var files: [URL] = []
        var seen = Set<String>()
        for url in resolved.map(\.targetURL) + resolved.map(\.embeddedURL) + extras {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path),
                  MachOIdentifier.isMachO(fileAt: url) else { continue }
            files.append(url)
        }
        return files
    }

    private static func snapshotMachO(in app: URL) throws -> [MachOArtifactSnapshot] {
        let files = FileSystemHelper.allFiles(in: app) { MachOIdentifier.isMachO(fileAt: $0) }
        return try snapshotMachO(files: files, in: app, detailed: true)
    }

    private static func snapshotMachO(
        files: [URL],
        in app: URL,
        detailed: Bool
    ) throws -> [MachOArtifactSnapshot] {
        let snapshots = try files.compactMap { file -> MachOArtifactSnapshot? in
            guard let relative = relativePath(file, under: app) else { return nil }
            let inspections = try DylibInjector.inspectLoadCommands(fileAt: file)
            let slices = inspections.map { slice in
                MachOSliceSnapshot(
                    index: slice.index,
                    loadCommands: slice.commands.map {
                        MachOLoadCommandSnapshot(path: $0.path, weak: $0.weak)
                    }
                )
            }
            let loadPaths = inspections.flatMap(\.commands).map(\.path)
            if detailed {
                let analysis = try DylibService.analyze(fileAt: file)
                return MachOArtifactSnapshot(
                    relativePath: relative,
                    sha256: analysis.sha256,
                    architectures: analysis.architectures,
                    slices: slices,
                    dependencies: analysis.dependencies.map(\.path).sorted(),
                    rpaths: analysis.rpaths.sorted(),
                    signature: analysis.signature
                )
            }
            return MachOArtifactSnapshot(
                relativePath: relative,
                sha256: try DylibService.sha256(fileAt: file),
                architectures: [],
                slices: slices,
                dependencies: Array(Set(loadPaths)).sorted(),
                rpaths: [],
                signature: .unavailable
            )
        }
        return snapshots.sorted { $0.relativePath < $1.relativePath }
    }

    private static func dependencyContext(
        providedNames: Set<String>,
        appFileNames: Set<String>
    ) -> DependencyClassificationContext {
        DependencyClassificationContext(
            appEmbeddedNames: appFileNames,
            pluginProvidedNames: providedNames
        )
    }

    /// 本机无法确认的依赖(deviceProvided / unknown)。判定完全委托给 DependencyClassifier,
    /// 不再保留第二套「/usr/lib 一律当系统库」的乐观逻辑。systemLibrary/appEmbedded/pluginProvided
    /// 属于已解析,不在返回值内。
    private static func unconfirmedDependencies(
        of analysis: DylibAnalysisSnapshot,
        context: DependencyClassificationContext
    ) -> [DependencyClassificationResult] {
        DependencyClassifier
            .classify(paths: analysis.dependencies.map(\.path), context: context)
            .filter { !$0.isResolvedLocally }
    }

    private static func validateAppDirectory(_ app: URL) throws {
        guard app.pathExtension.lowercased() == "app", FileSystemHelper.isDirectory(app) else {
            throw IpaError.appNotFound
        }
        let root = app.standardizedFileURL.path + "/"
        var count = 0
        var total: UInt64 = 0
        for file in FileSystemHelper.allFiles(in: app, where: { _ in true }) {
            count += 1
            guard count <= ArchiveLimits.default.maxEntries else {
                throw ArchiveSafetyError.entryLimit(count)
            }
            guard file.standardizedFileURL.path.hasPrefix(root) else {
                throw IpaInjectionWorkflowError.pathEscapesApp(file.path)
            }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
            if values.isSymbolicLink == true { throw ArchiveSafetyError.symbolicLink(file.path) }
            if values.isRegularFile == true {
                let size = UInt64(max(0, values.fileSize ?? 0))
                guard size <= ArchiveLimits.default.maxSingleFileBytes else {
                    throw ArchiveSafetyError.singleFileLimit(path: file.path, size: size)
                }
                total += size
                guard total <= ArchiveLimits.default.maxTotalBytes else {
                    throw ArchiveSafetyError.totalSizeLimit(total)
                }
            }
        }
    }

    private static func containedURL(_ path: ValidatedRelativePath, in app: URL) throws -> URL {
        let result = app.appendingPathComponent(path.rawValue).standardizedFileURL
        let root = app.standardizedFileURL.path + "/"
        guard result.path.hasPrefix(root) else {
            throw IpaInjectionWorkflowError.pathEscapesApp(path.rawValue)
        }
        return result
    }

    private static func owningExecutableBundle(for target: URL, app: URL) -> URL? {
        var current = target.deletingLastPathComponent()
        let root = app.standardizedFileURL
        while current.standardizedFileURL.path.hasPrefix(root.path) {
            let ext = current.pathExtension.lowercased()
            if ext == "appex" || ext == "app" { return current }
            if current.standardizedFileURL == root { return root }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private static func relativePath(_ url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return nil }
        return String(path.dropFirst(rootPath.count))
    }

    private static func relativePath(from directory: URL, to file: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = file.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] {
            common += 1
        }
        let components = Array(repeating: "..", count: from.count - common) + Array(to.dropFirst(common))
        return components.joined(separator: "/")
    }

    private static func outputDestination(
        plan: ValidatedInjectionPlan,
        override: URL?
    ) throws -> URL {
        if let override { return override }
        let parent = plan.input.url.deletingLastPathComponent()
        let directory: URL
        if isWritableDirectory(parent) {
            directory = parent
        } else {
            // 工作台的 IPA 快照目录是 0o555，不能在旁边落产物。
            directory = try FileSystemHelper.makeTemporaryDirectory(prefix: "injection-output")
        }
        return outputURL(for: plan, in: directory)
    }

    private static func outputURL(for plan: ValidatedInjectionPlan, in directory: URL) -> URL {
        let isIPA: Bool
        switch plan.input {
        case .ipa: isIPA = true
        case .app: isIPA = false
        }
        let suffix = isIPA ? "ipa" : "app"
        if let custom = plan.customOutputName {
            let name = custom.hasSuffix(".\(suffix)") ? custom : "\(custom).\(suffix)"
            return directory.appendingPathComponent(name)
        }
        let stem = plan.input.url.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(stem).injected.\(suffix)")
    }

    /// 半成品 zip / .app 先写到执行工作目录，再 move 到最终输出。
    private static func stagingURL(for output: URL, in work: URL) -> URL {
        work.appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).partial")
    }

    private static func isWritableDirectory(_ url: URL) -> Bool {
        guard FileSystemHelper.isDirectory(url) else { return false }
        guard let perms = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            return FileManager.default.isWritableFile(atPath: url.path)
        }
        return (perms.intValue & 0o200) != 0
    }
}

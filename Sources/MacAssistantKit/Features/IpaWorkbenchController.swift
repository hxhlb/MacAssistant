import Combine
import Foundation

/// 工作台里的一个插件。可能来自直接拖入的 dylib,也可能来自 .deb 里的候选。默认全部注入。
public struct WorkbenchPlugin: Identifiable, Sendable {
    public let id: UUID
    public let dylibURL: URL
    public let displayName: String
    /// 来自 .deb 时的包内相对路径;直接 dylib 为 nil。
    public let relativePath: String?
    public let filterTargets: TweakFilterTargets
    /// 来自哪个 .deb(文件名);直接 dylib 为 nil。
    public let sourceDebName: String?

    public init(
        id: UUID = UUID(),
        dylibURL: URL,
        displayName: String,
        relativePath: String? = nil,
        filterTargets: TweakFilterTargets = .init(),
        sourceDebName: String? = nil
    ) {
        self.id = id
        self.dylibURL = dylibURL
        self.displayName = displayName
        self.relativePath = relativePath
        self.filterTargets = filterTargets
        self.sourceDebName = sourceDebName
    }
}

/// 拖入式 IPA 工作台的状态机与编排器。判断逻辑委托给 Kit 层的纯函数
/// (`WorkspaceInputClassifier` / `WorkspaceSigningPlanner` / `WorkbenchTweakEvaluator` /
/// `WorkspacePlanAssembler`),这里只负责持有状态、分桶输入,并把三态串起来。
@MainActor
public final class IpaWorkbenchController: ObservableObject {

    // MARK: 输入分桶(工作项 1)
    @Published public private(set) var target: WorkspaceInputClassification?
    @Published public private(set) var snapshot: ImmutableSourceSnapshot?
    @Published public private(set) var plugins: [WorkbenchPlugin] = []
    @Published public private(set) var directDylibs: [URL] = []
    @Published public private(set) var frameworks: [URL] = []
    @Published public private(set) var bundles: [URL] = []
    @Published public private(set) var provisioningProfiles: [URL] = []
    @Published public var pendingCertificateURL: URL?
    /// 工作台 p12 明文密码。默认 `1`，用户可改。
    @Published public var developerCertificatePassword = SigningService.defaultDeveloperCertificatePassword
    @Published public private(set) var unrecognized: [URL] = []

    /// 被用户关掉的插件。未列入的一律注入——工作台默认全注入。
    @Published public var disabledPluginIDs: Set<UUID> = []
    @Published public var acknowledgedFilterMismatch = false

    // MARK: 目标上下文
    @Published public private(set) var targetIdentity: TweakFilterTargetIdentity?
    @Published public private(set) var requiredProfileBundleIDs: [String] = []
    /// 当前目标包 Info.plist 里的显示名 / 包名 / 版本，供预设输入框自动填充。
    @Published public private(set) var sourceAppMetadata: AppBundleMetadataSummary?

    // MARK: 签名材料(工作项 4)
    @Published public var selectedIdentity: SigningIdentity?
    @Published public private(set) var profilesByBundleID: [String: URL] = [:]
    @Published public var appleIDRecipe: AppleIDSigningRecipe?

    // MARK: 预设(工作项 3)
    @Published public var recipe: InjectionRecipe

    // MARK: 预检(工作项 2:执行前独立可见)
    @Published public private(set) var preflightReport: IpaPreflightReport?

    // MARK: 结果
    @Published public private(set) var phase: WorkspaceRunPhase = .sourceSnapshot
    @Published public private(set) var artifactState: WorkspaceArtifactState?
    @Published public private(set) var audit: WorkspaceAuditReport?
    /// 执行结果原件,供 UI 展示「未确认依赖」与「前后 diff」——这些是第二期诚实报告的核心,不能吞。
    @Published public private(set) var executionResult: IpaInjectionExecutionResult?

    /// 持有 DEB 扫描会话,保证其私有解包目录在计划执行前不被释放。
    private var candidateSessions: [DebTweakCandidateSession] = []

    public init(recipe: InjectionRecipe = InjectionRecipe(name: "")) {
        self.recipe = recipe
    }

    // MARK: - 分类入口

    public func classify(_ urls: [URL]) -> [WorkspaceInputClassification] {
        WorkspaceInputClassifier.classify(urls)
    }

    /// 工作台里已经同时有 p12 和至少一份描述文件。
    public var hasCertificateSideloadPair: Bool {
        pendingCertificateURL != nil && !provisioningProfiles.isEmpty
    }

    /// 同步把一批 URL 按角色分桶。DEB 与目标包需要额外异步处理,返回给调用方在任务里跟进。
    /// 同一批或与已有材料凑齐 p12 + 描述文件时，自动切到 P12 证书侧载。
    /// - Returns: 需要异步处理的目标包与 DEB。
    @discardableResult
    public func ingestSimpleInputs(_ urls: [URL]) -> (targets: [URL], debs: [URL]) {
        var pendingTargets: [URL] = []
        var pendingDebs: [URL] = []
        var touchedCertificateMaterials = false
        for classification in classify(urls) {
            switch classification.role {
            case .ipa, .app:
                pendingTargets.append(classification.url)
            case .deb:
                pendingDebs.append(classification.url)
            case .dylib:
                addDirectDylib(classification.url)
            case .framework:
                if !frameworks.contains(classification.url) { frameworks.append(classification.url) }
            case .bundle:
                if !bundles.contains(classification.url) { bundles.append(classification.url) }
            case .provisioningProfile:
                addProvisioningProfile(classification.url)
                touchedCertificateMaterials = true
            case .developerCertificate:
                pendingCertificateURL = classification.url
                touchedCertificateMaterials = true
            case .unrecognized:
                if !unrecognized.contains(classification.url) { unrecognized.append(classification.url) }
            }
        }
        if touchedCertificateMaterials {
            adoptCertificateSideloadIfPairReady()
        }
        return (pendingTargets, pendingDebs)
    }

    /// p12 和描述文件必须配套使用；两者都在时默认走证书侧载。
    private func adoptCertificateSideloadIfPairReady() {
        guard hasCertificateSideloadPair else { return }
        recipe.sideloadSigning = .p12
    }

    private func addDirectDylib(_ url: URL) {
        guard !directDylibs.contains(url) else { return }
        directDylibs.append(url)
        let plugin = WorkbenchPlugin(
            dylibURL: url,
            displayName: url.lastPathComponent,
            filterTargets: TweakFilterService.parseFilter(
                at: url.deletingPathExtension().appendingPathExtension("plist")
            )
        )
        plugins.append(plugin)
    }

    // MARK: - 目标包(工作项 6:不可变源快照)

    /// 建立目标包的不可变源快照(同步版,便于测试)。原始文件被复制进只读私有目录,
    /// 后续一切操作都在副本上做。UI 里因快照复制可能很大,改用 `adoptSnapshot` 在后台做完再登记。
    public func setTarget(_ url: URL) throws {
        let classification = WorkspaceInputClassifier.classify(url)
        guard classification.isTarget else { return }
        adoptSnapshot(try ImmutableSourceSnapshot.make(of: url))
    }

    /// 登记一个已在后台建立好的源快照。仅做主线程状态赋值,不含 I/O。
    public func adoptSnapshot(_ snapshot: ImmutableSourceSnapshot) {
        self.target = WorkspaceInputClassifier.classify(snapshot.originalURL)
        self.snapshot = snapshot
        self.phase = .sourceSnapshot
        self.artifactState = nil
        self.audit = nil
        sourceAppMetadata = nil
        clearIdentityOverrides()
    }

    /// 从源快照读取目标身份与需覆盖的 profile bundle ID(同步版,便于测试)。
    public func loadTargetContext() throws {
        guard let snapshot else { return }
        let session = try InjectionTargetDiscovery.open(snapshot.injectionInput)
        let identity = try TweakFilterService.targetIdentity(forAppAt: session.appURL, components: session.components)
        let required = (try? SigningService.profileBundleIDs(in: session.appURL)) ?? []
        applyTargetContext(identity: identity, requiredBundleIDs: required)
        applySourceMetadata(try AppBundleMetadataSummary.read(from: session.appURL))
    }

    /// 登记后台读到的目标上下文。仅做赋值。
    public func applyTargetContext(identity: TweakFilterTargetIdentity?, requiredBundleIDs: [String]) {
        self.targetIdentity = identity
        self.requiredProfileBundleIDs = requiredBundleIDs
        recomputeProfileMapping()
    }

    public func applySourceMetadata(_ summary: AppBundleMetadataSummary) {
        sourceAppMetadata = summary
    }

    public var isWeChatTarget: Bool { sourceAppMetadata?.isWeChat == true }

    /// 换包时清掉上一份的包名/显示名覆盖，让新包的 Info.plist 重新填进输入框。开关类预设保留。
    private func clearIdentityOverrides() {
        recipe.metadata.displayName = nil
        recipe.metadata.bundleID = nil
        recipe.metadata.shortVersion = nil
        recipe.metadata.buildVersion = nil
        recipe.metadata.minimumOSVersion = nil
    }

    // MARK: - DEB 摄取

    /// 扫描并摄取一个 .deb：抽出全部 tweak dylib，默认全部注入。
    /// 维护脚本 / daemon 等特征只作分类，不拦截。
    public func ingestDeb(_ url: URL) throws {
        let session = try TweakInjectService.candidateSession(inDebAt: url)
        attachDeb(session: session, sourceName: url.lastPathComponent)
    }

    /// 登记后台扫描好的 .deb 会话，把包内 dylib 全部加入插件列表。
    public func attachDeb(session: DebTweakCandidateSession, sourceName: String) {
        candidateSessions.append(session)
        for candidate in session.candidates {
            plugins.append(WorkbenchPlugin(
                id: candidate.id,
                dylibURL: candidate.dylibURL,
                displayName: candidate.dylibURL.lastPathComponent,
                relativePath: candidate.relativePath,
                filterTargets: candidate.filterTargets,
                sourceDebName: sourceName
            ))
        }
    }

    public var enabledPlugins: [WorkbenchPlugin] {
        plugins.filter { !disabledPluginIDs.contains($0.id) }
    }

    public func setPluginEnabled(_ id: UUID, _ enabled: Bool) {
        if enabled {
            disabledPluginIDs.remove(id)
        } else {
            disabledPluginIDs.insert(id)
        }
    }

    /// 某一条插件的可选宿主。没指定就是主程序，不套全局 3 → 2 → ProtobufLite。
    public func injectionHost(for plugin: WorkbenchPlugin) -> PreferredInjectionHost.Choice {
        recipe.mapping(for: plugin.dylibURL.lastPathComponent)?.injectionHost ?? .automatic
    }

    public func setPluginInjectionHost(_ id: UUID, _ host: PreferredInjectionHost.Choice) {
        guard let plugin = plugins.first(where: { $0.id == id }) else { return }
        let name = plugin.dylibURL.lastPathComponent
        var mappings = recipe.targetMappings
        if let index = mappings.firstIndex(where: { $0.dylibName == name }) {
            mappings[index].injectionHost = host
        } else {
            mappings.append(RecipeTargetMapping(dylibName: name, injectionHost: host))
        }
        recipe.targetMappings = mappings
    }

    // MARK: - 签名材料

    /// 加入一个 provisioning profile,读取其 appID 后按需覆盖的 bundle ID 建立映射。
    public func addProvisioningProfile(_ url: URL) {
        guard !provisioningProfiles.contains(url) else { return }
        provisioningProfiles.append(url)
        recomputeProfileMapping()
    }

    /// 按 profile 的 appID 与目标需要的 bundle ID 逐一匹配(支持通配 `*`)。
    private func recomputeProfileMapping() {
        profilesByBundleID = SigningService.mapProfiles(provisioningProfiles, onto: requiredProfileBundleIDs)
    }

    /// appID 形如 `TEAMID.com.foo.bar` 或 `TEAMID.com.foo.*`;去掉 team 前缀后与 bundleID 比对。
    nonisolated static func appID(_ appID: String, matches bundleID: String) -> Bool {
        SigningService.profileAppID(appID, matches: bundleID)
    }

    // MARK: - 派生决策(全部委托纯函数)

    /// 当前签名三态。选「不签名」时一律未签名，不因半成品 Apple ID / p12 卡住。
    public var signingDecision: WorkspaceSigningDecision {
        WorkspaceSigningPlanner.decide(
            identity: selectedIdentity,
            profilesByBundleID: profilesByBundleID,
            requiredBundleIDs: requiredProfileBundleIDs,
            appleID: appleIDRecipe,
            extraProfiles: provisioningProfiles,
            certificateURL: pendingCertificateURL,
            certificatePassword: developerCertificatePassword,
            method: recipe.sideloadSigning
        )
    }

    /// 执行层签名模式。不签名时强制 `.none`。
    public var resolvedSigningMode: InjectionSigningMode {
        if recipe.sideloadSigning == .none { return .none }
        return WorkspaceSigningPlanner.signingMode(for: signingDecision, fallback: .adHoc)
    }

    /// 每个已启用插件与目标 filter 的比对。目标身份未载入时为空(尚不能判定)。
    public var pluginChoices: [(plugin: WorkbenchPlugin, choice: WorkbenchTweakChoice)] {
        guard let identity = targetIdentity else { return [] }
        return enabledPlugins.map { plugin in
            (
                plugin,
                WorkbenchTweakEvaluator.evaluate(
                    filter: plugin.filterTargets,
                    against: identity,
                    acknowledgedMismatch: acknowledgedFilterMismatch
                )
            )
        }
    }

    public func choice(for plugin: WorkbenchPlugin) -> WorkbenchTweakChoice? {
        pluginChoices.first { $0.plugin.id == plugin.id }?.choice
    }

    /// 任一已启用插件的 filter 不匹配且未知情确认时阻止。
    public var isFilterBlocked: Bool { pluginChoices.contains { $0.choice.isBlocked } }

    /// 勾了移除组件但未确认时拦住，避免点执行才抛错。
    public var isComponentRemovalBlocked: Bool {
        recipe.components.removesAnything && !recipe.components.destructiveRemovalConfirmed
    }

    /// 有源快照、至少启用一个插件、filter 未拦、签名三态允许、预检无 blocker。
    public var canExecute: Bool {
        snapshot != nil
            && !enabledPlugins.isEmpty
            && !isFilterBlocked
            && !isComponentRemovalBlocked
            && signingDecision.canExecute
            && !preflightHasBlockers
    }

    /// 已启用插件按加入顺序注入;若预设里写了文件名顺序则按该顺序排。
    public var orderedDylibs: [URL] {
        let enabled = enabledPlugins
        guard !recipe.injectionOrder.isEmpty else { return enabled.map(\.dylibURL) }
        return enabled.sorted { lhs, rhs in
            let left = recipe.injectionOrder.firstIndex(of: lhs.displayName) ?? Int.max
            let right = recipe.injectionOrder.firstIndex(of: rhs.displayName) ?? Int.max
            return left < right
        }.map(\.dylibURL)
    }

    // MARK: - 预检(工作项 2)

    /// 登记后台跑出的预检报告,进入 `.preflighted` 阶段。让用户在执行前先看到问题。
    public func applyPreflight(_ report: IpaPreflightReport) {
        preflightReport = report
        phase = .preflighted
    }

    /// 一份汇总的阻止/告警清单:预检 findings + 主 tweak filter 比对。
    /// 用户应在一处看到所有原因,而不是散落在各卡片或点了执行才被抛错拦住。
    public var combinedPreflightFindings: [IpaPreflightFinding] {
        var findings = preflightReport?.findings ?? []
        for item in pluginChoices { findings += item.choice.evaluation.findings }
        return findings
    }

    /// 预检是否发现 blocker。仅在已跑过预检时据此拦执行(未跑预检不因此拦,execute 仍会兜底)。
    public var preflightHasBlockers: Bool { preflightReport?.hasBlockers ?? false }

    /// 组装可执行的 `InjectionPlan`。会把当前注入顺序写回 recipe。
    public func buildPlan() throws -> InjectionPlan {
        guard let snapshot else { throw InjectionPlanError.validation([]) }
        let ordered = orderedDylibs
        recipe.injectionOrder = ordered.map(\.lastPathComponent)
        let inputs = WorkspacePlanAssembler.Inputs(
            input: snapshot.injectionInput,
            orderedDylibs: ordered,
            frameworks: frameworks,
            recipe: recipe,
            signing: resolvedSigningMode
        )
        return try WorkspacePlanAssembler.makePlan(inputs)
    }

    /// 计划执行需要授予安全作用域访问的全部 URL(原始输入 + 各资源)。
    public var accessURLs: [URL] {
        var urls = snapshot.map { [$0.originalURL, $0.snapshotURL] } ?? []
        if let original = snapshot?.originalURL {
            urls.append(original.deletingLastPathComponent())
        }
        urls += plugins.map(\.dylibURL)
        urls += frameworks
        urls += bundles
        urls += Array(profilesByBundleID.values)
        return urls
    }

    /// 产物写在用户原始 IPA/App 旁边，绝不写进只读的 `workspace-source` 快照目录。
    public var proposedOutputURL: URL? {
        guard let original = snapshot?.originalURL else { return nil }
        let isIPA = original.pathExtension.lowercased() == "ipa"
        let stem = original.deletingPathExtension().lastPathComponent
        let proposed = original.deletingLastPathComponent()
            .appendingPathComponent("\(stem).injected.\(isIPA ? "ipa" : "app")")
        return FileSystemHelper.uniqueOutputURL(basedOn: proposed)
    }

    // MARK: - 结果录入(工作项 3、6)

    /// 执行成功后录入结果:推导产物三态,并生成默认脱敏的审计报告。
    public func recordExecution(
        _ result: IpaInjectionExecutionResult,
        toolVersion: String
    ) {
        let decision = signingDecision
        artifactState = decision.artifactState(outputURL: result.outputURL)
        executionResult = result
        // 执行内部会重跑预检,取其结果让预检卡在执行后仍反映真实 findings。
        preflightReport = result.preflight
        phase = .handoff

        var pluginHashes: [String: String] = [:]
        for plugin in plugins {
            pluginHashes[plugin.displayName] = (try? DylibService.sha256(fileAt: plugin.dylibURL)) ?? ""
        }
        audit = WorkspaceAuditReport(
            toolVersion: toolVersion,
            inputName: snapshot?.originalURL.lastPathComponent ?? "",
            inputSHA256: snapshot?.sha256 ?? "",
            outputName: result.outputURL.lastPathComponent,
            outputSHA256: nil,
            pluginHashes: pluginHashes,
            targetProfileBundleIDs: requiredProfileBundleIDs,
            finalInjectedDylibPosition: WorkspacePlanAssembler.finalDylibPosition(from: result),
            findings: result.preflight.findings,
            changedPaths: result.diff.changedPaths,
            unconfirmedDependencies: result.audit.unconfirmedDependencies,
            signingOutcome: Self.signingOutcomeDescription(decision)
        )
    }

    // MARK: - Recipe 落盘(工作项 3)

    /// 保存当前 recipe 到文件。先把当前注入顺序写回,保证保存的是「所见即所存」。
    /// recipe 只含设置、不含文件 URL,因此这份文件能复用到不同拖入来源。
    public func saveRecipe(to url: URL) throws {
        recipe.injectionOrder = orderedDylibs.map(\.lastPathComponent)
        try recipe.save(to: url)
    }

    /// 从文件载入 recipe 并应用。schema 不认识时 `InjectionRecipe.load` 会抛错,这里不吞、不猜。
    public func loadRecipe(from url: URL) throws {
        recipe = try InjectionRecipe.load(from: url)
    }

    static func signingOutcomeDescription(_ decision: WorkspaceSigningDecision) -> String {
        switch decision {
        case .unsigned: return "modified-unsigned"
        case .readyToSign: return "signed-for-handoff (pending on-device verification)"
        case .readyToSignWithAppleID: return "signed-for-handoff-appleid (pending on-device verification)"
        case .waitingForAssets: return "waiting-for-signing-assets"
        }
    }

    public func markPhase(_ phase: WorkspaceRunPhase) {
        self.phase = phase
    }

    public func reset() {
        target = nil
        snapshot = nil
        plugins = []
        directDylibs = []
        frameworks = []
        bundles = []
        provisioningProfiles = []
        pendingCertificateURL = nil
        developerCertificatePassword = SigningService.defaultDeveloperCertificatePassword
        unrecognized = []
        disabledPluginIDs = []
        acknowledgedFilterMismatch = false
        targetIdentity = nil
        requiredProfileBundleIDs = []
        sourceAppMetadata = nil
        selectedIdentity = nil
        profilesByBundleID = [:]
        appleIDRecipe = nil
        candidateSessions = []
        preflightReport = nil
        phase = .sourceSnapshot
        artifactState = nil
        audit = nil
        executionResult = nil
    }
}

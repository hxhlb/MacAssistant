import Combine
import Foundation

/// IPA 工具箱「提取头文件」的可观察会话。
///
/// 状态必须活在这个对象里，而不是 `ClassDumpTab` 的 `@State`：侧栏 `switch` 和
/// 工具箱 tab `switch` 都会拆掉对应 View，只有上层用 `@StateObject` 持有本对象，
/// 结果页、日志和输入才能在回来后还在。
@MainActor
public final class ClassDumpSession: ObservableObject {
    @Published public var inputURLs: [URL] = []
    @Published public var outputDirectory: URL?
    @Published public var archText = ""
    @Published public var allowExternalEnhancement = true
    @Published public var facts: MachOFacts?
    @Published public var inspecting = false
    @Published public var busy = false
    @Published public var ok: Bool?
    @Published public var log = ""
    @Published public var headers = ""

    public init() {}

    public var hasPersistedResult: Bool {
        !log.isEmpty || !headers.isEmpty
    }
}

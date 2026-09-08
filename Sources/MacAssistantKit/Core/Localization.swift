import Foundation

/// 界面语言。`rawValue` 直接用作 `.lproj` 目录名，新增一门语言只需增加一个 case，
/// 并在两个 target 的 `Localization/<rawValue>.lproj/` 下各放一份 `Localizable.strings`。
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case spanish = "es"
    case korean = "ko"
    case russian = "ru"

    public var id: String { rawValue }

    /// 可实际取词条的语言，按「先具体后宽泛」排序，匹配时优先命中 zh-Hans 而不是假想的 zh。
    public static var translations: [AppLanguage] {
        allCases.filter { $0 != .system }.sorted { $0.rawValue.count > $1.rawValue.count }
    }

    /// 除「跟随系统」外一律用语言自身的写法，避免用户误切到看不懂的语言后找不回来。
    public var displayName: String {
        switch self {
        case .system: return MALocalizedString("language.system", bundle: .module)
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .spanish: return "Español"
        case .korean: return "한국어"
        case .russian: return "Русский"
        }
    }

    /// 系统语言标签。`zh-TW` / `zh-HK` 归繁体，`zh` / `zh-CN` 归简体。
    public var languageTags: [String] {
        switch self {
        case .system: return []
        case .simplifiedChinese: return ["zh-hans", "zh-cn", "zh-sg"]
        case .traditionalChinese: return ["zh-hant", "zh-tw", "zh-hk", "zh-mo"]
        case .english: return ["en"]
        case .spanish: return ["es"]
        case .korean: return ["ko"]
        case .russian: return ["ru"]
        }
    }

    public func matches(languageIdentifier wanted: String) -> Bool {
        let wanted = Self.normalize(wanted)
        guard !wanted.isEmpty else { return false }
        let candidate = rawValue.lowercased()
        if wanted == candidate || wanted.hasPrefix(candidate + "-") { return true }
        for tag in languageTags {
            if wanted == tag || wanted.hasPrefix(tag + "-") { return true }
        }
        return false
    }

    /// 自己做语言匹配而不用 `Bundle.preferredLocalizations(from:)`：后者依赖主 bundle 的
    /// 本地化列表，裸 SwiftPM 可执行文件下会恒定返回 en。
    public static func bestMatch(for preferences: [String]) -> AppLanguage? {
        for preference in preferences {
            let wanted = normalize(preference)
            if let match = translations.first(where: { $0.matches(languageIdentifier: wanted) }) {
                return match
            }
            if wanted == "zh" || wanted.hasPrefix("zh-") {
                return isTraditionalChinese(wanted) ? .traditionalChinese : .simplifiedChinese
            }
        }
        return nil
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    private static func isTraditionalChinese(_ wanted: String) -> Bool {
        wanted.contains("hant")
            || wanted.hasPrefix("zh-tw")
            || wanted.hasPrefix("zh-hk")
            || wanted.hasPrefix("zh-mo")
    }
}

public enum LocalizationSettings {
    public static let defaultsKey = "MacAssistantInterfaceLanguage"

    /// 测试需要一个确定的语言，否则断言会随宿主系统语言漂移。
    public static var override: AppLanguage?

    public static var current: AppLanguage {
        get {
            if let override { return override }
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let language = AppLanguage(rawValue: raw)
            else {
                return .system
            }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}

/// 开发语言：任何语言缺词条时回退到这里，而不是把 key 直接显示给用户。
private let developmentLanguage = AppLanguage.simplifiedChinese

/// 从指定 bundle 取本地化字符串。
///
/// SwiftUI 的 `Text("key")` 只查 `Bundle.main`，而 SwiftPM 把资源放在各 target 的
/// `Bundle.module` 里，所以全项目统一走这里显式指定 bundle。
public func MALocalizedString(
    _ key: String,
    arguments: [CVarArg] = [],
    bundle: Bundle
) -> String {
    let template = LocalizationEngine.shared.string(for: key, in: bundle)
    guard !arguments.isEmpty else { return template }
    return String(format: template, arguments: arguments)
}

private let missingMarker = "\u{0}MA_MISSING\u{0}"

private final class LocalizationEngine: @unchecked Sendable {
    static let shared = LocalizationEngine()

    private let lock = NSLock()
    private var bundles: [String: Bundle] = [:]

    func string(for key: String, in base: Bundle) -> String {
        let chain = [resolvedLanguage(), developmentLanguage]
        for language in chain {
            guard let table = lproj(language, in: base) else { continue }
            let value = table.localizedString(forKey: key, value: missingMarker, table: nil)
            if value != missingMarker { return value }
        }
        return key
    }

    private func resolvedLanguage() -> AppLanguage {
        let preference = LocalizationSettings.current
        guard preference == .system else { return preference }
        return Self.bestMatch(for: Locale.preferredLanguages) ?? developmentLanguage
    }

    static func bestMatch(for preferences: [String]) -> AppLanguage? {
        AppLanguage.bestMatch(for: preferences)
    }

    private func lproj(_ language: AppLanguage, in base: Bundle) -> Bundle? {
        let key = "\(ObjectIdentifier(base).hashValue)|\(language.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = bundles[key] { return cached }
        guard let url = Self.lprojURL(language.rawValue, in: base),
              let resolved = Bundle(url: url)
        else {
            return nil
        }
        bundles[key] = resolved
        return resolved
    }

    /// SwiftPM 会把 `zh-Hans.lproj` 写成 `zh-hans.lproj`，按名字精确查会落空，
    /// 因此退化成大小写不敏感的目录扫描。
    private static func lprojURL(_ language: String, in base: Bundle) -> URL? {
        if let path = base.path(forResource: language, ofType: "lproj") {
            return URL(fileURLWithPath: path)
        }
        guard let resources = base.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: resources,
                  includingPropertiesForKeys: nil
              )
        else {
            return nil
        }
        let wanted = "\(language).lproj".lowercased()
        return entries.first { $0.lastPathComponent.lowercased() == wanted }
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    MALocalizedString(key, arguments: arguments, bundle: .module)
}

func L(_ key: String, arguments: [CVarArg]) -> String {
    MALocalizedString(key, arguments: arguments, bundle: .module)
}

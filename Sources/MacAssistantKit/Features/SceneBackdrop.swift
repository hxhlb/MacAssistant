import Foundation

/// 页面背景。配色灵感来自常见 Mac 软件的界面氛围，不是官方主题或壁纸拷贝。
public enum SceneBackdropID: String, CaseIterable, Identifiable, Sendable {
    case system
    case safari
    case music
    case notes
    case freeform
    case shortcuts
    case podcasts
    case things
    case arc
    case linear
    case nightGreen
    case starfield

    public var id: String { rawValue }

    public var isDecorative: Bool { self != .system }

    /// 暗夜绿 / 星空本身就是深色氛围，选中后整窗跟深色外观走，避免浅色文字叠在深底上。
    public var prefersDarkAppearance: Bool {
        self == .nightGreen || self == .starfield
    }

    public var title: String {
        L("scene.\(rawValue)")
    }

    public var symbolName: String {
        switch self {
        case .system: return "rectangle"
        case .safari: return "safari"
        case .music: return "music.note"
        case .notes: return "note.text"
        case .freeform: return "circle.grid.3x3"
        case .shortcuts: return "square.stack.3d.up"
        case .podcasts: return "mic.fill"
        case .things: return "checkmark.circle"
        case .arc: return "paintpalette"
        case .linear: return "square.grid.2x2"
        case .nightGreen: return "leaf.fill"
        case .starfield: return "sparkles"
        }
    }

    public static func resolved(_ raw: String?) -> SceneBackdropID {
        guard let raw, let value = SceneBackdropID(rawValue: raw) else { return .system }
        return value
    }

    public func recipe(dark: Bool) -> SceneBackdropRecipe {
        switch self {
        case .system:
            return .systemPlaceholder
        case .safari:
            return dark ? .safariDark : .safariLight
        case .music:
            return dark ? .musicDark : .musicLight
        case .notes:
            return dark ? .notesDark : .notesLight
        case .freeform:
            return dark ? .freeformDark : .freeformLight
        case .shortcuts:
            return dark ? .shortcutsDark : .shortcutsLight
        case .podcasts:
            return dark ? .podcastsDark : .podcastsLight
        case .things:
            return dark ? .thingsDark : .thingsLight
        case .arc:
            return dark ? .arcDark : .arcLight
        case .linear:
            return dark ? .linearDark : .linearLight
        case .nightGreen:
            return dark ? .nightGreenDark : .nightGreenLight
        case .starfield:
            return dark ? .starfieldDark : .starfieldLight
        }
    }
}

public enum SceneBackdropSettings {
    public static let defaultsKey = "MacAssistantSceneBackdrop"
    public static let motionDefaultsKey = "MacAssistantSceneMotion"
}

/// 界面外观。暗夜绿 / 星空仍强制深色配方，避免浅色文字叠在深底上。
public enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public static let defaultsKey = "MacAssistantAppearance"

    public static func resolved(_ raw: String?) -> AppearancePreference {
        AppearancePreference(rawValue: raw ?? "") ?? .system
    }

    public var title: String {
        L("appearance.\(rawValue)")
    }

    /// `nil` 跟随系统；`true` 夜间；`false` 日间。
    public var prefersDark: Bool? {
        switch self {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }
}

/// 侧栏材质。默认走系统侧栏 / 液态玻璃；半透明会透出桌面或当前页面背景。
public enum SidebarAppearance: String, CaseIterable, Identifiable, Sendable {
    case material
    case translucent

    public var id: String { rawValue }

    public static let defaultsKey = "MacAssistantSidebarAppearance"

    public static func resolved(_ raw: String?) -> SidebarAppearance {
        SidebarAppearance(rawValue: raw ?? "") ?? .material
    }

    public var title: String {
        L("sidebar.appearance.\(rawValue)")
    }

    /// 侧栏材质落到窗口、列表底板和系统玻璃上的具体策略。
    public func chrome(decorativeScene: Bool, reduceTransparency: Bool) -> SidebarChromePolicy {
        SidebarChromePolicy.resolve(
            appearance: self,
            decorativeScene: decorativeScene,
            reduceTransparency: reduceTransparency
        )
    }
}

/// 「系统材质 / 半透明」对窗口不透明、侧栏玻璃、内容区底板的影响。
///
/// 减弱透明度时一律按系统材质处理，避免只剩一块全透明侧栏。
/// 系统默认背景下不能把整窗 `backgroundColor` 设成透明：内容区若没铺实底，窗口会从屏幕上消失。
/// 半透明在系统背景下改走更透的侧栏玻璃（behind-window），桌面从侧栏透出来；内容区保持系统窗底。
public struct SidebarChromePolicy: Equatable, Sendable {
    /// 侧栏去掉系统底板，让后面的场景或桌面露出来。
    public let letsBackgroundThrough: Bool
    /// 窗口是否保持系统不透明底板。装饰场景才为 false。
    public let windowOpaque: Bool
    /// 装饰背景 + 半透明：关掉侧栏玻璃，让页面场景直接露出来。
    public let hidesSidebarMaterial: Bool
    /// 系统背景 + 半透明：侧栏改用更透的玻璃，而不是拆掉整窗底板。
    public let usesClearSidebarGlass: Bool
    /// 装饰背景下保留材质时，玻璃采样窗口内的场景而不是桌面。
    public let blendsMaterialWithinWindow: Bool

    public static func resolve(
        appearance: SidebarAppearance,
        decorativeScene: Bool,
        reduceTransparency: Bool
    ) -> SidebarChromePolicy {
        let translucent = appearance == .translucent && !reduceTransparency
        return SidebarChromePolicy(
            letsBackgroundThrough: decorativeScene || translucent,
            windowOpaque: !decorativeScene,
            hidesSidebarMaterial: translucent && decorativeScene,
            usesClearSidebarGlass: translucent && !decorativeScene,
            blendsMaterialWithinWindow: decorativeScene && !translucent
        )
    }
}

/// 侧栏符号颜色。默认黑白；彩色按功能着色；其余与「文件改色」同一套预设，加自选颜色。
public struct IconAppearance: Hashable, Identifiable, Sendable {
    public let rawValue: String

    public var id: String { rawValue }

    public static let defaultsKey = "MacAssistantIconAppearance"
    public static let customDefaultsKey = "MacAssistantIconCustomColor"
    /// 彩色模式下的洗牌种子。每次点「彩色」换一局，侧栏图标重新配色。
    public static let colorSeedDefaultsKey = "MacAssistantIconColorSeed"

    public static let monochrome = IconAppearance(rawValue: "monochrome")
    public static let color = IconAppearance(rawValue: "color")

    public enum Kind: Equatable, Sendable {
        case monochrome
        case color
        case palette(String)
        case custom(red: Double, green: Double, blue: Double)
    }

    /// 文件改色那一行实色，不含「系统蓝」（那边是保留原文件夹颜色）。
    public static var palettePresets: [DesktopIconPreset] {
        DesktopIconPresets.colors.filter { !$0.keepOriginalColor }
    }

    public static func palette(_ key: String) -> IconAppearance {
        resolved("palette.\(key)")
    }

    public static func custom(red: Double, green: Double, blue: Double) -> IconAppearance {
        let clamp: (Double) -> Int = { max(0, min(255, Int(($0 * 255.0).rounded()))) }
        return resolved(String(format: "custom.%02x%02x%02x", clamp(red), clamp(green), clamp(blue)))
    }

    public static func custom(hex: String) -> IconAppearance {
        resolved("custom.\(hex)")
    }

    public static func resolved(_ raw: String?) -> IconAppearance {
        let value = raw ?? ""
        if value == color.rawValue { return .color }
        if value.hasPrefix("palette.") {
            let key = String(value.dropFirst("palette.".count))
            if palettePresets.contains(where: { $0.key == key }) {
                return IconAppearance(rawValue: value)
            }
        }
        if let hex = Self.normalizedCustomHex(value) {
            return IconAppearance(rawValue: "custom.\(hex)")
        }
        return .monochrome
    }

    public var kind: Kind {
        if rawValue == Self.color.rawValue { return .color }
        if rawValue.hasPrefix("palette.") {
            return .palette(String(rawValue.dropFirst("palette.".count)))
        }
        if let rgb = customRGB {
            return .custom(red: rgb.0, green: rgb.1, blue: rgb.2)
        }
        return .monochrome
    }

    public var usesHierarchicalColor: Bool {
        kind != .monochrome
    }

    public var rgb: (Double, Double, Double)? {
        switch kind {
        case .monochrome, .color:
            return nil
        case .palette(let key):
            guard let preset = Self.palettePresets.first(where: { $0.key == key }) else { return nil }
            return (preset.red, preset.green, preset.blue)
        case .custom(let red, let green, let blue):
            return (red, green, blue)
        }
    }

    public var customHex: String? {
        guard rawValue.hasPrefix("custom.") else { return nil }
        return String(rawValue.dropFirst("custom.".count))
    }

    public var title: String {
        switch kind {
        case .monochrome: return L("icon.appearance.monochrome")
        case .color: return L("icon.appearance.color")
        case .palette(let key): return L("desktopicon.preset.color.\(key)")
        case .custom: return L("icon.appearance.custom")
        }
    }

    private var customRGB: (Double, Double, Double)? {
        guard let hex = customHex, let packed = Int(hex, radix: 16), hex.count == 6 else { return nil }
        return (
            Double((packed >> 16) & 0xFF) / 255.0,
            Double((packed >> 8) & 0xFF) / 255.0,
            Double(packed & 0xFF) / 255.0
        )
    }

    private static func normalizedCustomHex(_ raw: String) -> String? {
        guard raw.hasPrefix("custom.") else { return nil }
        let hex = String(raw.dropFirst("custom.".count)).lowercased()
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

/// 彩色模式：按种子把一组饱和色洗牌后分给侧栏项。同一种子结果稳定。
public enum SidebarIconShuffle: Sendable {
    public static func nextSeed() -> Int {
        var seed = 0
        while seed == 0 {
            seed = Int.random(in: Int.min ... Int.max)
        }
        return seed
    }

    public static func rgb(for item: SidebarItem, seed: Int) -> (Double, Double, Double) {
        let items = Array(SidebarItem.allCases)
        guard let index = items.firstIndex(of: item) else { return palette[0] }
        var bag = palette
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed == 0 ? 1 : seed)))
        for i in stride(from: bag.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            bag.swapAt(i, j)
        }
        return bag[index % bag.count]
    }

    private static let palette: [(Double, Double, Double)] = [
        (0.18, 0.70, 0.68),
        (0.94, 0.50, 0.18),
        (0.90, 0.30, 0.28),
        (0.22, 0.54, 0.92),
        (0.40, 0.42, 0.88),
        (0.62, 0.34, 0.84),
        (0.16, 0.70, 0.80),
        (0.22, 0.76, 0.58),
        (0.70, 0.46, 0.26),
        (0.92, 0.40, 0.60),
        (0.30, 0.70, 0.36),
        (0.54, 0.36, 0.78),
        (0.92, 0.70, 0.18),
        (0.16, 0.56, 0.52),
        (0.84, 0.32, 0.46),
        (0.28, 0.48, 0.90),
        (0.76, 0.40, 0.18)
    ]
}

private struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public struct SceneColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

public struct SceneBlob: Sendable, Equatable {
    public let color: SceneColor
    public let x: Double
    public let y: Double
    public let radius: Double
    public let opacity: Double

    public init(_ color: SceneColor, x: Double, y: Double, radius: Double, opacity: Double) {
        self.color = color
        self.x = x
        self.y = y
        self.radius = radius
        self.opacity = opacity
    }
}

public enum SceneOverlay: String, Sendable, Equatable, CaseIterable {
    case hills
    case paperLines
    case dots
    case rings
    case grain
    case spotlight
    case stars
}

public struct SceneBackdropRecipe: Sendable, Equatable {
    public let base: SceneColor
    public let secondary: SceneColor
    public let blobs: [SceneBlob]
    public let overlays: [SceneOverlay]
    public let hillColors: [SceneColor]
    public let mesh: [SceneColor]
    public let cardOpacity: Double
    public let looksDark: Bool

    public init(
        base: SceneColor,
        secondary: SceneColor,
        blobs: [SceneBlob] = [],
        overlays: [SceneOverlay] = [],
        hillColors: [SceneColor] = [],
        mesh: [SceneColor] = [],
        cardOpacity: Double,
        looksDark: Bool
    ) {
        self.base = base
        self.secondary = secondary
        self.blobs = blobs
        self.overlays = overlays
        self.hillColors = hillColors
        self.mesh = mesh
        self.cardOpacity = cardOpacity
        self.looksDark = looksDark
    }
}

extension SceneBackdropRecipe {
    static let systemPlaceholder = SceneBackdropRecipe(
        base: SceneColor(0.95, 0.95, 0.97),
        secondary: SceneColor(0.95, 0.95, 0.97),
        cardOpacity: 1,
        looksDark: false
    )

    // MARK: 晴空 — 连续天色，不用色带远山

    static let safariLight = SceneBackdropRecipe(
        base: SceneColor(0.93, 0.91, 0.90),
        secondary: SceneColor(0.82, 0.88, 0.90),
        blobs: [
            SceneBlob(SceneColor(1.00, 0.94, 0.88), x: 0.18, y: 0.12, radius: 0.62, opacity: 0.42),
            SceneBlob(SceneColor(0.78, 0.90, 0.96), x: 0.82, y: 0.16, radius: 0.58, opacity: 0.38),
            SceneBlob(SceneColor(0.70, 0.84, 0.86), x: 0.48, y: 0.78, radius: 0.55, opacity: 0.28)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.97, 0.92, 0.88), SceneColor(0.92, 0.93, 0.94), SceneColor(0.84, 0.91, 0.96),
            SceneColor(0.92, 0.90, 0.88), SceneColor(0.86, 0.90, 0.92), SceneColor(0.78, 0.88, 0.92),
            SceneColor(0.82, 0.86, 0.86), SceneColor(0.74, 0.84, 0.86), SceneColor(0.68, 0.82, 0.86)
        ),
        cardOpacity: 0.36,
        looksDark: false
    )

    static let safariDark = SceneBackdropRecipe(
        base: SceneColor(0.10, 0.14, 0.20),
        secondary: SceneColor(0.08, 0.16, 0.22),
        blobs: [
            SceneBlob(SceneColor(0.72, 0.48, 0.38), x: 0.20, y: 0.10, radius: 0.50, opacity: 0.22),
            SceneBlob(SceneColor(0.28, 0.48, 0.68), x: 0.82, y: 0.18, radius: 0.55, opacity: 0.28),
            SceneBlob(SceneColor(0.18, 0.32, 0.42), x: 0.50, y: 0.78, radius: 0.50, opacity: 0.20)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.16, 0.14, 0.18), SceneColor(0.12, 0.16, 0.24), SceneColor(0.12, 0.18, 0.28),
            SceneColor(0.12, 0.16, 0.22), SceneColor(0.10, 0.16, 0.24), SceneColor(0.09, 0.18, 0.26),
            SceneColor(0.08, 0.16, 0.20), SceneColor(0.07, 0.14, 0.20), SceneColor(0.06, 0.12, 0.18)
        ),
        cardOpacity: 0.30,
        looksDark: true
    )

    // MARK: Music — 专辑色光斑

    static let musicLight = SceneBackdropRecipe(
        base: SceneColor(0.96, 0.94, 0.96),
        secondary: SceneColor(0.94, 0.92, 0.95),
        blobs: [
            SceneBlob(SceneColor(0.90, 0.22, 0.48), x: 0.12, y: 0.78, radius: 0.48, opacity: 0.42),
            SceneBlob(SceneColor(0.12, 0.72, 0.86), x: 0.88, y: 0.28, radius: 0.42, opacity: 0.38),
            SceneBlob(SceneColor(0.95, 0.70, 0.22), x: 0.72, y: 0.88, radius: 0.38, opacity: 0.34),
            SceneBlob(SceneColor(0.55, 0.28, 0.86), x: 0.18, y: 0.22, radius: 0.30, opacity: 0.26)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.90, 0.72, 0.92), SceneColor(0.96, 0.94, 0.96), SceneColor(0.62, 0.88, 0.96),
            SceneColor(0.96, 0.78, 0.86), SceneColor(0.95, 0.93, 0.95), SceneColor(0.78, 0.86, 0.96),
            SceneColor(0.94, 0.62, 0.78), SceneColor(0.96, 0.86, 0.62), SceneColor(0.86, 0.78, 0.94)
        ),
        cardOpacity: 0.62,
        looksDark: false
    )

    static let musicDark = SceneBackdropRecipe(
        base: SceneColor(0.043, 0.043, 0.051),
        secondary: SceneColor(0.07, 0.06, 0.09),
        blobs: [
            SceneBlob(SceneColor(0.88, 0.12, 0.45), x: 0.16, y: 0.78, radius: 0.55, opacity: 0.55),
            SceneBlob(SceneColor(0.10, 0.78, 0.90), x: 0.86, y: 0.26, radius: 0.48, opacity: 0.48),
            SceneBlob(SceneColor(0.96, 0.72, 0.18), x: 0.70, y: 0.88, radius: 0.42, opacity: 0.40),
            SceneBlob(SceneColor(0.52, 0.22, 0.90), x: 0.22, y: 0.20, radius: 0.36, opacity: 0.32)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.12, 0.05, 0.16), SceneColor(0.05, 0.05, 0.07), SceneColor(0.04, 0.16, 0.22),
            SceneColor(0.18, 0.04, 0.12), SceneColor(0.05, 0.04, 0.07), SceneColor(0.06, 0.12, 0.20),
            SceneColor(0.16, 0.04, 0.10), SceneColor(0.12, 0.08, 0.05), SceneColor(0.08, 0.06, 0.04)
        ),
        cardOpacity: 0.48,
        looksDark: true
    )

    // MARK: Notes — 淡黄纸

    static let notesLight = SceneBackdropRecipe(
        base: SceneColor(0.996, 0.962, 0.72),
        secondary: SceneColor(0.98, 0.92, 0.62),
        blobs: [
            SceneBlob(SceneColor(1.0, 0.98, 0.86), x: 0.50, y: 0.08, radius: 0.70, opacity: 0.40)
        ],
        overlays: [.paperLines, .grain],
        mesh: mesh(
            SceneColor(1.00, 0.98, 0.82), SceneColor(0.99, 0.96, 0.74), SceneColor(0.99, 0.95, 0.70),
            SceneColor(0.99, 0.96, 0.74), SceneColor(0.99, 0.95, 0.70), SceneColor(0.98, 0.93, 0.66),
            SceneColor(0.98, 0.93, 0.66), SceneColor(0.97, 0.91, 0.60), SceneColor(0.96, 0.88, 0.55)
        ),
        cardOpacity: 0.70,
        looksDark: false
    )

    static let notesDark = SceneBackdropRecipe(
        base: SceneColor(0.165, 0.145, 0.090),
        secondary: SceneColor(0.22, 0.19, 0.12),
        blobs: [
            SceneBlob(SceneColor(0.32, 0.26, 0.14), x: 0.50, y: 0.12, radius: 0.65, opacity: 0.35)
        ],
        overlays: [.paperLines, .grain],
        mesh: mesh(
            SceneColor(0.20, 0.17, 0.11), SceneColor(0.17, 0.15, 0.09), SceneColor(0.16, 0.14, 0.08),
            SceneColor(0.18, 0.16, 0.10), SceneColor(0.16, 0.14, 0.09), SceneColor(0.15, 0.13, 0.08),
            SceneColor(0.15, 0.13, 0.08), SceneColor(0.14, 0.12, 0.07), SceneColor(0.12, 0.10, 0.06)
        ),
        cardOpacity: 0.55,
        looksDark: true
    )

    // MARK: Freeform — 点阵画布

    static let freeformLight = SceneBackdropRecipe(
        base: SceneColor(0.965, 0.957, 0.937),
        secondary: SceneColor(0.94, 0.93, 0.90),
        overlays: [.dots],
        mesh: mesh(
            SceneColor(0.98, 0.97, 0.95), SceneColor(0.97, 0.96, 0.94), SceneColor(0.96, 0.95, 0.93),
            SceneColor(0.97, 0.96, 0.94), SceneColor(0.96, 0.95, 0.93), SceneColor(0.95, 0.94, 0.91),
            SceneColor(0.95, 0.94, 0.91), SceneColor(0.94, 0.93, 0.90), SceneColor(0.93, 0.92, 0.88)
        ),
        cardOpacity: 0.78,
        looksDark: false
    )

    static let freeformDark = SceneBackdropRecipe(
        base: SceneColor(0.118, 0.118, 0.110),
        secondary: SceneColor(0.10, 0.10, 0.09),
        overlays: [.dots],
        mesh: mesh(
            SceneColor(0.14, 0.14, 0.13), SceneColor(0.12, 0.12, 0.11), SceneColor(0.11, 0.11, 0.10),
            SceneColor(0.12, 0.12, 0.11), SceneColor(0.11, 0.11, 0.10), SceneColor(0.10, 0.10, 0.09),
            SceneColor(0.10, 0.10, 0.09), SceneColor(0.09, 0.09, 0.08), SceneColor(0.08, 0.08, 0.07)
        ),
        cardOpacity: 0.58,
        looksDark: true
    )

    // MARK: Shortcuts — 珊瑚到蓝的色块

    static let shortcutsLight = SceneBackdropRecipe(
        base: SceneColor(0.996, 0.961, 0.941),
        secondary: SceneColor(0.96, 0.90, 0.94),
        blobs: [
            SceneBlob(SceneColor(1.00, 0.42, 0.29), x: 0.12, y: 0.22, radius: 0.46, opacity: 0.42),
            SceneBlob(SceneColor(1.00, 0.56, 0.68), x: 0.48, y: 0.78, radius: 0.44, opacity: 0.36),
            SceneBlob(SceneColor(0.38, 0.62, 0.98), x: 0.88, y: 0.28, radius: 0.42, opacity: 0.34),
            SceneBlob(SceneColor(0.96, 0.76, 0.22), x: 0.78, y: 0.86, radius: 0.32, opacity: 0.28),
            SceneBlob(SceneColor(0.72, 0.48, 0.98), x: 0.22, y: 0.72, radius: 0.30, opacity: 0.22)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(1.00, 0.62, 0.48), SceneColor(0.99, 0.86, 0.78), SceneColor(0.72, 0.82, 0.98),
            SceneColor(0.99, 0.72, 0.70), SceneColor(0.98, 0.90, 0.88), SceneColor(0.82, 0.78, 0.96),
            SceneColor(0.98, 0.70, 0.78), SceneColor(0.96, 0.82, 0.70), SceneColor(0.90, 0.78, 0.92)
        ),
        cardOpacity: 0.60,
        looksDark: false
    )

    static let shortcutsDark = SceneBackdropRecipe(
        base: SceneColor(0.102, 0.071, 0.094),
        secondary: SceneColor(0.14, 0.08, 0.12),
        blobs: [
            SceneBlob(SceneColor(0.96, 0.36, 0.24), x: 0.14, y: 0.24, radius: 0.48, opacity: 0.50),
            SceneBlob(SceneColor(0.96, 0.42, 0.58), x: 0.50, y: 0.80, radius: 0.46, opacity: 0.42),
            SceneBlob(SceneColor(0.32, 0.55, 0.96), x: 0.88, y: 0.26, radius: 0.44, opacity: 0.40),
            SceneBlob(SceneColor(0.94, 0.72, 0.18), x: 0.78, y: 0.86, radius: 0.34, opacity: 0.32),
            SceneBlob(SceneColor(0.66, 0.40, 0.96), x: 0.20, y: 0.74, radius: 0.32, opacity: 0.28)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.28, 0.10, 0.10), SceneColor(0.16, 0.08, 0.10), SceneColor(0.10, 0.12, 0.28),
            SceneColor(0.24, 0.08, 0.14), SceneColor(0.12, 0.07, 0.10), SceneColor(0.14, 0.10, 0.24),
            SceneColor(0.22, 0.08, 0.16), SceneColor(0.18, 0.10, 0.08), SceneColor(0.16, 0.08, 0.18)
        ),
        cardOpacity: 0.48,
        looksDark: true
    )

    // MARK: Podcasts — 紫与环形波

    static let podcastsLight = SceneBackdropRecipe(
        base: SceneColor(0.953, 0.910, 0.996),
        secondary: SceneColor(0.92, 0.84, 0.98),
        blobs: [
            SceneBlob(SceneColor(0.49, 0.23, 0.93), x: 0.78, y: 0.22, radius: 0.50, opacity: 0.32),
            SceneBlob(SceneColor(0.86, 0.15, 0.47), x: 0.18, y: 0.78, radius: 0.42, opacity: 0.24),
            SceneBlob(SceneColor(0.38, 0.32, 0.90), x: 0.88, y: 0.72, radius: 0.34, opacity: 0.18)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.94, 0.88, 0.99), SceneColor(0.90, 0.84, 0.98), SceneColor(0.82, 0.72, 0.96),
            SceneColor(0.93, 0.86, 0.98), SceneColor(0.90, 0.82, 0.96), SceneColor(0.78, 0.68, 0.94),
            SceneColor(0.90, 0.78, 0.92), SceneColor(0.86, 0.72, 0.90), SceneColor(0.72, 0.58, 0.88)
        ),
        cardOpacity: 0.62,
        looksDark: false
    )

    static let podcastsDark = SceneBackdropRecipe(
        base: SceneColor(0.102, 0.063, 0.157),
        secondary: SceneColor(0.14, 0.06, 0.22),
        blobs: [
            SceneBlob(SceneColor(0.66, 0.42, 0.98), x: 0.78, y: 0.22, radius: 0.52, opacity: 0.48),
            SceneBlob(SceneColor(0.95, 0.28, 0.58), x: 0.16, y: 0.78, radius: 0.44, opacity: 0.36),
            SceneBlob(SceneColor(0.42, 0.32, 0.90), x: 0.88, y: 0.70, radius: 0.36, opacity: 0.28)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.16, 0.08, 0.24), SceneColor(0.14, 0.07, 0.22), SceneColor(0.22, 0.10, 0.36),
            SceneColor(0.14, 0.07, 0.20), SceneColor(0.12, 0.06, 0.18), SceneColor(0.20, 0.08, 0.32),
            SceneColor(0.16, 0.06, 0.18), SceneColor(0.18, 0.06, 0.20), SceneColor(0.12, 0.05, 0.16)
        ),
        cardOpacity: 0.48,
        looksDark: true
    )

    // MARK: Things — 亚麻

    static let thingsLight = SceneBackdropRecipe(
        base: SceneColor(0.953, 0.929, 0.894),
        secondary: SceneColor(0.91, 0.86, 0.80),
        blobs: [
            SceneBlob(SceneColor(0.91, 0.77, 0.66), x: 0.86, y: 0.82, radius: 0.48, opacity: 0.28),
            SceneBlob(SceneColor(0.98, 0.94, 0.88), x: 0.18, y: 0.12, radius: 0.55, opacity: 0.40)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.97, 0.94, 0.90), SceneColor(0.95, 0.93, 0.89), SceneColor(0.94, 0.91, 0.86),
            SceneColor(0.95, 0.92, 0.88), SceneColor(0.94, 0.91, 0.86), SceneColor(0.92, 0.88, 0.82),
            SceneColor(0.93, 0.88, 0.82), SceneColor(0.90, 0.84, 0.76), SceneColor(0.88, 0.80, 0.70)
        ),
        cardOpacity: 0.68,
        looksDark: false
    )

    static let thingsDark = SceneBackdropRecipe(
        base: SceneColor(0.141, 0.122, 0.102),
        secondary: SceneColor(0.18, 0.15, 0.12),
        blobs: [
            SceneBlob(SceneColor(0.32, 0.24, 0.18), x: 0.84, y: 0.80, radius: 0.46, opacity: 0.32),
            SceneBlob(SceneColor(0.22, 0.18, 0.14), x: 0.18, y: 0.14, radius: 0.50, opacity: 0.28)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.18, 0.15, 0.12), SceneColor(0.15, 0.13, 0.10), SceneColor(0.14, 0.12, 0.10),
            SceneColor(0.16, 0.14, 0.11), SceneColor(0.14, 0.12, 0.10), SceneColor(0.13, 0.11, 0.09),
            SceneColor(0.14, 0.12, 0.10), SceneColor(0.13, 0.11, 0.09), SceneColor(0.11, 0.09, 0.07)
        ),
        cardOpacity: 0.52,
        looksDark: true
    )

    // MARK: Arc — Space 色块

    static let arcLight = SceneBackdropRecipe(
        base: SceneColor(0.992, 0.965, 0.973),
        secondary: SceneColor(0.96, 0.94, 0.98),
        blobs: [
            SceneBlob(SceneColor(0.98, 0.45, 0.55), x: 0.18, y: 0.28, radius: 0.50, opacity: 0.38),
            SceneBlob(SceneColor(0.40, 0.88, 0.96), x: 0.78, y: 0.22, radius: 0.46, opacity: 0.36),
            SceneBlob(SceneColor(0.99, 0.73, 0.45), x: 0.86, y: 0.78, radius: 0.42, opacity: 0.32),
            SceneBlob(SceneColor(0.64, 0.90, 0.42), x: 0.22, y: 0.82, radius: 0.38, opacity: 0.26),
            SceneBlob(SceneColor(0.72, 0.58, 0.98), x: 0.52, y: 0.52, radius: 0.34, opacity: 0.18)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.98, 0.72, 0.78), SceneColor(0.96, 0.88, 0.92), SceneColor(0.72, 0.90, 0.96),
            SceneColor(0.96, 0.80, 0.82), SceneColor(0.94, 0.90, 0.94), SceneColor(0.82, 0.86, 0.96),
            SceneColor(0.86, 0.92, 0.70), SceneColor(0.96, 0.84, 0.70), SceneColor(0.86, 0.76, 0.94)
        ),
        cardOpacity: 0.58,
        looksDark: false
    )

    static let arcDark = SceneBackdropRecipe(
        base: SceneColor(0.102, 0.078, 0.125),
        secondary: SceneColor(0.12, 0.08, 0.16),
        blobs: [
            SceneBlob(SceneColor(0.96, 0.40, 0.58), x: 0.16, y: 0.28, radius: 0.52, opacity: 0.48),
            SceneBlob(SceneColor(0.13, 0.83, 0.93), x: 0.80, y: 0.20, radius: 0.48, opacity: 0.44),
            SceneBlob(SceneColor(0.98, 0.58, 0.22), x: 0.86, y: 0.80, radius: 0.44, opacity: 0.40),
            SceneBlob(SceneColor(0.54, 0.86, 0.22), x: 0.20, y: 0.84, radius: 0.40, opacity: 0.32),
            SceneBlob(SceneColor(0.58, 0.42, 0.96), x: 0.50, y: 0.50, radius: 0.36, opacity: 0.24)
        ],
        overlays: [.grain],
        mesh: mesh(
            SceneColor(0.28, 0.08, 0.16), SceneColor(0.14, 0.08, 0.16), SceneColor(0.06, 0.18, 0.24),
            SceneColor(0.20, 0.08, 0.16), SceneColor(0.10, 0.07, 0.14), SceneColor(0.10, 0.12, 0.24),
            SceneColor(0.12, 0.16, 0.08), SceneColor(0.22, 0.12, 0.06), SceneColor(0.16, 0.08, 0.22)
        ),
        cardOpacity: 0.46,
        looksDark: true
    )

    // MARK: Linear — 暗夜与靛光

    static let linearLight = SceneBackdropRecipe(
        base: SceneColor(0.969, 0.969, 0.973),
        secondary: SceneColor(0.94, 0.94, 0.96),
        blobs: [
            SceneBlob(SceneColor(0.39, 0.40, 0.95), x: 0.90, y: 0.08, radius: 0.48, opacity: 0.28),
            SceneBlob(SceneColor(0.56, 0.27, 0.90), x: 0.12, y: 0.88, radius: 0.36, opacity: 0.16)
        ],
        overlays: [.grain, .spotlight],
        mesh: mesh(
            SceneColor(0.94, 0.94, 0.98), SceneColor(0.96, 0.96, 0.98), SceneColor(0.78, 0.80, 0.96),
            SceneColor(0.96, 0.96, 0.98), SceneColor(0.95, 0.95, 0.97), SceneColor(0.88, 0.88, 0.96),
            SceneColor(0.90, 0.88, 0.96), SceneColor(0.94, 0.94, 0.96), SceneColor(0.92, 0.92, 0.96)
        ),
        cardOpacity: 0.72,
        looksDark: false
    )

    static let linearDark = SceneBackdropRecipe(
        base: SceneColor(0.047, 0.047, 0.055),
        secondary: SceneColor(0.07, 0.07, 0.09),
        blobs: [
            SceneBlob(SceneColor(0.31, 0.27, 0.90), x: 0.88, y: 0.10, radius: 0.50, opacity: 0.32),
            SceneBlob(SceneColor(0.18, 0.12, 0.40), x: 0.12, y: 0.86, radius: 0.40, opacity: 0.22)
        ],
        overlays: [.grain, .spotlight],
        mesh: mesh(
            SceneColor(0.07, 0.07, 0.10), SceneColor(0.05, 0.05, 0.07), SceneColor(0.10, 0.09, 0.22),
            SceneColor(0.05, 0.05, 0.06), SceneColor(0.05, 0.05, 0.06), SceneColor(0.07, 0.07, 0.12),
            SceneColor(0.06, 0.05, 0.08), SceneColor(0.05, 0.05, 0.06), SceneColor(0.04, 0.04, 0.05)
        ),
        cardOpacity: 0.50,
        looksDark: true
    )

    // MARK: 暗夜绿
    //
    // 参考 Linear / Raycast 暗色画布：近黑绿底、角落月光、颗粒和暗角。
    // 不用远山层——深色底上的正弦条带会看起来像一条斜丝带。

    static let nightGreenLight = SceneBackdropRecipe(
        base: SceneColor(0.07, 0.11, 0.09),
        secondary: SceneColor(0.05, 0.08, 0.07),
        blobs: [
            SceneBlob(SceneColor(0.16, 0.38, 0.28), x: 0.92, y: 0.08, radius: 0.58, opacity: 0.28),
            SceneBlob(SceneColor(0.08, 0.20, 0.16), x: 0.06, y: 0.92, radius: 0.50, opacity: 0.22)
        ],
        overlays: [.grain, .spotlight],
        mesh: mesh(
            SceneColor(0.08, 0.13, 0.11), SceneColor(0.07, 0.11, 0.09), SceneColor(0.12, 0.20, 0.16),
            SceneColor(0.06, 0.10, 0.08), SceneColor(0.07, 0.11, 0.09), SceneColor(0.08, 0.13, 0.10),
            SceneColor(0.05, 0.08, 0.07), SceneColor(0.05, 0.08, 0.07), SceneColor(0.06, 0.09, 0.08)
        ),
        cardOpacity: 0.30,
        looksDark: true
    )

    static let nightGreenDark = SceneBackdropRecipe(
        base: SceneColor(0.035, 0.055, 0.045),
        secondary: SceneColor(0.025, 0.04, 0.035),
        blobs: [
            SceneBlob(SceneColor(0.10, 0.32, 0.22), x: 0.94, y: 0.06, radius: 0.62, opacity: 0.30),
            SceneBlob(SceneColor(0.05, 0.14, 0.11), x: 0.04, y: 0.94, radius: 0.52, opacity: 0.22)
        ],
        overlays: [.grain, .spotlight],
        mesh: mesh(
            SceneColor(0.04, 0.07, 0.06), SceneColor(0.035, 0.055, 0.045), SceneColor(0.08, 0.16, 0.12),
            SceneColor(0.03, 0.05, 0.04), SceneColor(0.035, 0.055, 0.045), SceneColor(0.045, 0.08, 0.06),
            SceneColor(0.025, 0.04, 0.035), SceneColor(0.025, 0.04, 0.035), SceneColor(0.03, 0.05, 0.04)
        ),
        cardOpacity: 0.26,
        looksDark: true
    )

    // MARK: 星空渐变

    static let starfieldLight = SceneBackdropRecipe(
        base: SceneColor(0.08, 0.09, 0.18),
        secondary: SceneColor(0.05, 0.06, 0.14),
        blobs: [
            SceneBlob(SceneColor(0.28, 0.22, 0.62), x: 0.78, y: 0.18, radius: 0.50, opacity: 0.40),
            SceneBlob(SceneColor(0.18, 0.12, 0.42), x: 0.18, y: 0.72, radius: 0.46, opacity: 0.32),
            SceneBlob(SceneColor(0.42, 0.28, 0.72), x: 0.52, y: 0.42, radius: 0.30, opacity: 0.22)
        ],
        overlays: [.stars, .grain, .spotlight],
        mesh: mesh(
            SceneColor(0.10, 0.12, 0.26), SceneColor(0.08, 0.09, 0.20), SceneColor(0.16, 0.12, 0.36),
            SceneColor(0.07, 0.08, 0.18), SceneColor(0.06, 0.07, 0.16), SceneColor(0.12, 0.10, 0.28),
            SceneColor(0.05, 0.05, 0.12), SceneColor(0.04, 0.05, 0.12), SceneColor(0.08, 0.06, 0.18)
        ),
        cardOpacity: 0.28,
        looksDark: true
    )

    static let starfieldDark = SceneBackdropRecipe(
        base: SceneColor(0.03, 0.04, 0.08),
        secondary: SceneColor(0.02, 0.03, 0.07),
        blobs: [
            SceneBlob(SceneColor(0.22, 0.16, 0.55), x: 0.80, y: 0.16, radius: 0.52, opacity: 0.44),
            SceneBlob(SceneColor(0.12, 0.08, 0.32), x: 0.16, y: 0.76, radius: 0.48, opacity: 0.34),
            SceneBlob(SceneColor(0.36, 0.22, 0.64), x: 0.50, y: 0.40, radius: 0.32, opacity: 0.24)
        ],
        overlays: [.stars, .grain, .spotlight],
        mesh: mesh(
            SceneColor(0.05, 0.06, 0.16), SceneColor(0.03, 0.04, 0.10), SceneColor(0.12, 0.08, 0.28),
            SceneColor(0.03, 0.04, 0.09), SceneColor(0.03, 0.03, 0.08), SceneColor(0.08, 0.06, 0.18),
            SceneColor(0.02, 0.02, 0.06), SceneColor(0.02, 0.02, 0.06), SceneColor(0.05, 0.04, 0.12)
        ),
        cardOpacity: 0.24,
        looksDark: true
    )

    private static func mesh(
        _ c00: SceneColor, _ c10: SceneColor, _ c20: SceneColor,
        _ c01: SceneColor, _ c11: SceneColor, _ c21: SceneColor,
        _ c02: SceneColor, _ c12: SceneColor, _ c22: SceneColor
    ) -> [SceneColor] {
        [c00, c10, c20, c01, c11, c21, c02, c12, c22]
    }
}

import Foundation

public enum AppCloneRecipes {
    public static let weComBundleID = "com.tencent.WeWorkMac"

    public static let all: [AppCloneRecipe] = [
        cocoa("com.tencent.xinWeChat", "微信", extraLinks: [".ssh"]),
        electron("com.tencent.qq", "QQ"),
        electron("com.electron.lark", "飞书", stripURLSchemes: true),
        cocoa("ru.keepcoder.Telegram", "Telegram"),
        cocoa("org.telegram.desktop", "Telegram Desktop", kind: .generic),
        cocoa("jp.naver.line.mac", "LINE"),
        electron("com.tinyspeck.slackmacgap", "Slack"),
        electron("com.hnc.Discord", "Discord"),
        electron("com.skype.skype", "Skype"),
        electron(
            "com.anthropic.claudefordesktop",
            "Claude",
            arguments: ["--user-data-dir={{CLONE_DATA_DIR}}/UserData"],
            environment: ["CLAUDE_CONFIG_DIR": "{{CLONE_DATA_DIR}}/Claude"]
        ),
        electron(
            "com.openai.codex",
            "ChatGPT",
            stripURLSchemes: true,
            environment: ["CODEX_HOME": "{{CLONE_DATA_DIR}}/Codex"]
        ),
        electron(
            "com.openai.chat",
            "ChatGPT",
            stripURLSchemes: true,
            environment: ["CODEX_HOME": "{{CLONE_DATA_DIR}}/Codex"]
        ),
        cocoa(
            "com.google.GeminiMacOS",
            "Gemini",
            environment: [
                "GEMINI_HOME": "{{CLONE_DATA_DIR}}/Gemini",
                "GEMINI_CONFIG_DIR": "{{CLONE_DATA_DIR}}/Gemini",
                "ANTIGRAVITY_HOME": "{{CLONE_DATA_DIR}}/Gemini"
            ]
        ),
        electron(
            "com.google.antigravity",
            "Antigravity",
            arguments: ["--user-data-dir={{CLONE_DATA_DIR}}/UserData"],
            environment: [
                "GEMINI_HOME": "{{CLONE_DATA_DIR}}/Gemini",
                "GEMINI_CONFIG_DIR": "{{CLONE_DATA_DIR}}/Gemini",
                "ANTIGRAVITY_HOME": "{{CLONE_DATA_DIR}}/Gemini"
            ]
        ),
        electron(
            "com.google.antigravity-ide",
            "Antigravity IDE",
            arguments: ["--user-data-dir={{CLONE_DATA_DIR}}/UserData"],
            environment: [
                "GEMINI_HOME": "{{CLONE_DATA_DIR}}/Gemini",
                "GEMINI_CONFIG_DIR": "{{CLONE_DATA_DIR}}/Gemini",
                "ANTIGRAVITY_HOME": "{{CLONE_DATA_DIR}}/Gemini"
            ]
        ),
        AppCloneRecipe(
            bundleID: "com.google.Chrome",
            appName: "Chrome",
            strategy: .hard,
            kind: .chromium,
            launchArguments: ["--user-data-dir={{CLONE_DATA_DIR}}"]
        ),
        AppCloneRecipe(
            bundleID: "com.microsoft.edgemac",
            appName: "Edge",
            strategy: .hard,
            kind: .chromium,
            launchArguments: ["--user-data-dir={{CLONE_DATA_DIR}}"]
        ),
        AppCloneRecipe(
            bundleID: "com.brave.Browser",
            appName: "Brave",
            strategy: .soft,
            kind: .chromium,
            launchArguments: ["--user-data-dir={{CLONE_DATA_DIR}}"]
        ),
        AppCloneRecipe(
            bundleID: "org.mozilla.firefox",
            appName: "Firefox",
            strategy: .soft,
            kind: .firefox,
            launchArguments: ["-profile", "{{CLONE_DATA_DIR}}"]
        ),
        AppCloneRecipe(
            bundleID: "org.torproject.torbrowser",
            appName: "Tor Browser",
            strategy: .soft,
            kind: .firefox,
            launchArguments: ["-profile", "{{CLONE_DATA_DIR}}"]
        ),
        AppCloneRecipe(
            bundleID: "company.thebrowser.Browser",
            appName: "Arc",
            strategy: .hard,
            kind: .chromium,
            launchArguments: ["--user-data-dir={{CLONE_DATA_DIR}}"]
        ),
        electron("com.bilibili.bilibiliPC", "哔哩哔哩"),
        electron("com.bytedance.douyin.desktop", "抖音"),
        cocoa("com.netease.163music", "网易云音乐", kind: .chromium),
        cocoa("com.valvesoftware.steam", "Steam"),
        cocoa("com.kingsoft.wpsoffice.mac", "WPS Office"),
        cocoa("com.lemon.lvpro", "剪映专业版", kind: .chromium),
        cocoa("com.lemon.lvoverseas", "CapCut", kind: .chromium),
        AppCloneRecipe(
            bundleID: "com.todesktop.230313mzl4w4u92",
            appName: "Cursor",
            strategy: .soft,
            kind: .electron,
            launchArguments: ["--user-data-dir={{CLONE_DATA_DIR}}"]
        ),
        AppCloneRecipe(
            bundleID: "com.microsoft.VSCode",
            appName: "VS Code",
            strategy: .soft,
            kind: .electron,
            launchArguments: ["--user-data-dir={{CLONE_DATA_DIR}}"]
        ),
        cocoa("com.google.android.studio", "Android Studio", kind: .generic),
        AppCloneRecipe(
            bundleID: "dev.zed.Zed",
            appName: "Zed",
            strategy: .soft,
            kind: .generic,
            environment: isolatedHome
        ),
    ]

    public static func recipe(forBundleID bundleID: String) -> AppCloneRecipe? {
        let key = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.first { $0.bundleID.compare(key, options: .caseInsensitive) == .orderedSame }
    }

    public static func isBlocked(_ bundleID: String) -> Bool {
        bundleID.compare(weComBundleID, options: .caseInsensitive) == .orderedSame
    }

    private static func cocoa(
        _ bundleID: String,
        _ name: String,
        kind: AppCloneKind = .cocoa,
        extraLinks: [String] = [],
        environment: [String: String] = [:]
    ) -> AppCloneRecipe {
        var env = isolatedHome
        environment.forEach { env[$0.key] = $0.value }
        return AppCloneRecipe(
            bundleID: bundleID,
            appName: name,
            strategy: .hard,
            kind: kind,
            stripSandbox: true,
            environment: env,
            symlinkWhitelist: ["Library/Keychains"] + extraLinks
        )
    }

    private static func electron(
        _ bundleID: String,
        _ name: String,
        stripURLSchemes: Bool = false,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) -> AppCloneRecipe {
        var env = isolatedHome
        environment.forEach { env[$0.key] = $0.value }
        return AppCloneRecipe(
            bundleID: bundleID,
            appName: name,
            strategy: .hard,
            kind: .electron,
            stripSandbox: true,
            stripURLSchemes: stripURLSchemes,
            environment: env,
            launchArguments: arguments,
            symlinkWhitelist: ["Library/Keychains"]
        )
    }

    private static let isolatedHome = [
        "HOME": "{{CLONE_DATA_DIR}}/Home",
        "TMPDIR": "{{CLONE_DATA_DIR}}/Tmp",
    ]
}

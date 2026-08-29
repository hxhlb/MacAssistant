import Foundation

/// 内置注入流水线的进度行,格式对齐 injectipa:`>>> 解压IPA文件 <<<`。
///
/// 只负责措辞与装箱,不表示步骤已经发生;调用方必须在对应动作真正完成后
/// (或开始时)再发出,禁止用这些字符串假装做过可选步骤。
public enum InjectionProgressLog {
    public static func boxed(_ message: String) -> String {
        ">>> \(message) <<<"
    }

    public static func unzipStart() -> String {
        boxed(L("ipaflow.progress.unzip"))
    }

    public static func unzipProgress(_ percent: Int) -> String {
        boxed(L("ipaflow.progress.unzipPercent", percent))
    }

    public static func unzipSucceeded() -> String {
        boxed(L("ipaflow.progress.unzipOK"))
    }

    public static func appCopySucceeded() -> String {
        boxed(L("ipaflow.progress.appCopied"))
    }

    public static func copyDylibSucceeded(_ name: String) -> String {
        boxed(L("ipaflow.progress.copyDylibOK", name))
    }

    public static func injectStart(_ name: String) -> String {
        boxed(L("ipaflow.progress.inject", name))
    }

    public static func injectSucceeded(_ name: String) -> String {
        boxed(L("ipaflow.progress.injectOK", name))
    }

    public static func discoveredDependencies(_ name: String) -> String {
        boxed(L("ipaflow.progress.foundDeps", name))
    }

    public static func rewrittenDependencies(_ name: String) -> String {
        boxed(L("ipaflow.progress.rewriteDepsOK", name))
    }

    public static func removedPlugIns() -> String {
        boxed(L("ipaflow.progress.removePlugIns"))
    }

    public static func removedWatch() -> String {
        boxed(L("ipaflow.progress.removeWatch"))
    }

    public static func removedAppClips() -> String {
        boxed(L("ipaflow.progress.removeAppClips"))
    }

    public static func fileSharingEnabled() -> String {
        boxed(L("ipaflow.progress.fileSharing"))
    }

    public static func assetsCarRemoved(appName: String, rendition: String) -> String {
        boxed(L("ipaflow.progress.assetsCarRemoved", appName, rendition))
    }

    public static func zipStart() -> String {
        boxed(L("ipaflow.progress.zip"))
    }

    public static func zipProgress(_ percent: Int) -> String {
        boxed(L("ipaflow.progress.zipPercent", percent))
    }

    public static func zipSucceeded(_ path: String) -> String {
        boxed(L("ipaflow.progress.zipOK", path))
    }

    public static func appPackaged(_ path: String) -> String {
        boxed(L("ipaflow.progress.appPackaged", path))
    }

    public static func clearedCache() -> String {
        boxed(L("ipaflow.progress.clearCache"))
    }
}

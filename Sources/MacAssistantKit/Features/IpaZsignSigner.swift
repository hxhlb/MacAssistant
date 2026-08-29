import Foundation

/// 手机 IPA 的证书签名，对齐 LoadController：一份 p12 + 一份 mobileprovision，交给 zsign。
///
/// 和电脑软件签名不是一条路：
/// - 电脑 App / 公证：系统 `codesign`（见 `build_app.sh`）
/// - 越狱伪签名：`ldid` / `codesign -s -`
/// - 手机 IPA 真机证书：本类型，只走 zsign
public enum IpaZsignSigner {

    public static let installHint = "zsign（brew install zsign）"

    /// 判断这是不是给 iPhone / iPad 装的包。有 `Contents/MacOS` 的按电脑软件处理。
    public static func isIOSAppBundle(_ app: URL) -> Bool {
        let macOSDir = app.appendingPathComponent("Contents/MacOS")
        if FileManager.default.fileExists(atPath: macOSDir.path) {
            return false
        }
        guard let plist = try? IpaService.infoPlist(appBundle: app) else { return true }
        if plist["LSRequiresIPhoneOS"] as? Bool == true { return true }
        let platform = (plist["DTPlatformName"] as? String ?? "").lowercased()
        if platform.contains("macos") { return false }
        if platform.contains("iphone") || platform.contains("ipad") || platform.contains("ios") {
            return true
        }
        return true
    }

    /// zsign 只要一份描述文件。优先主 Bundle，其次映射里任意一份，再退回未匹配上的拖入文件。
    public static func primaryProvision(
        profilesByBundleID: [String: URL],
        preferring bundleID: String? = nil,
        extraProfiles: [URL] = []
    ) -> URL? {
        if let bundleID, let url = profilesByBundleID[bundleID] { return url }
        if let url = profilesByBundleID.values.first { return url }
        return extraProfiles.first
    }

    /// 组装 zsign 参数，顺序对齐 LoadController 的 `lc_zsign_sign_ipa`。
    public static func commandArguments(
        input: URL,
        p12URL: URL,
        p12Password: String,
        provisionURL: URL,
        outputIPA: URL? = nil,
        bundleIDOverride: String? = nil,
        bundleNameOverride: String? = nil,
        bundleVersionOverride: String? = nil
    ) -> [String] {
        var args = [
            "-k", p12URL.path,
            "-m", provisionURL.path,
            "-p", p12Password,
            "-z", "1"
        ]
        if let outputIPA {
            args += ["-o", outputIPA.path]
        }
        if let value = trimmed(bundleIDOverride) { args += ["-b", value] }
        if let value = trimmed(bundleNameOverride) { args += ["-n", value] }
        if let value = trimmed(bundleVersionOverride) { args += ["-r", value] }
        args.append(input.path)
        return args
    }

    /// 从证书库取 p12；没有文件就从钥匙串导出一份临时 p12。密码不会进日志。
    public static func resolveP12(
        for identity: SigningIdentity,
        workDirectory: URL
    ) throws -> (url: URL, password: String) {
        let stored = SigningCertificateLibrary.load()
        let selected = SigningCertificateLibrary.selected()
        let entry = stored.first {
            $0.id == selected?.id && $0.identityID.caseInsensitiveCompare(identity.id) == .orderedSame
        } ?? stored.first {
            $0.identityID.caseInsensitiveCompare(identity.id) == .orderedSame
        }
        if let entry {
            let url = SigningCertificateLibrary.p12URL(for: entry)
            if FileManager.default.fileExists(atPath: url.path) {
                return (url, SigningCertificateLibrary.password(for: entry.id) ?? "")
            }
        }
        let exported = workDirectory.appendingPathComponent("zsign-\(identity.id).p12")
        let password = UUID().uuidString
        try SigningService.exportDeveloperCertificate(identity: identity, to: exported, password: password)
        return (exported, password)
    }

    public static func sign(
        input: URL,
        p12URL: URL,
        p12Password: String,
        provisionURL: URL,
        outputIPA: URL? = nil,
        bundleIDOverride: String? = nil,
        bundleNameOverride: String? = nil,
        bundleVersionOverride: String? = nil,
        log: inout [String]
    ) throws {
        guard ExternalTool.zsign.isAvailable else {
            throw SigningError.toolMissing(installHint)
        }
        guard FileManager.default.fileExists(atPath: p12URL.path) else {
            throw SigningError.p12Unavailable
        }
        guard FileManager.default.fileExists(atPath: provisionURL.path) else {
            throw SigningError.missingProfileMappings(["mobileprovision"])
        }
        if let outputIPA {
            try FileManager.default.createDirectory(
                at: outputIPA.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        let args = commandArguments(
            input: input,
            p12URL: p12URL,
            p12Password: p12Password,
            provisionURL: provisionURL,
            outputIPA: outputIPA,
            bundleIDOverride: bundleIDOverride,
            bundleNameOverride: bundleNameOverride,
            bundleVersionOverride: bundleVersionOverride
        )
        log.append(L("signing.log.zsignStart", input.lastPathComponent, provisionURL.lastPathComponent))
        let result = try ExternalTool.zsign.run(args)
        guard result.succeeded else {
            throw SigningError.commandFailed(
                L("signing.error.zsignFailed", result.exitCode, result.combinedOutput)
            )
        }
        let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            log.append(contentsOf: output.split(separator: "\n").map(String.init))
        }
        log.append(L("signing.log.zsignDone"))
    }

    private static func trimmed(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

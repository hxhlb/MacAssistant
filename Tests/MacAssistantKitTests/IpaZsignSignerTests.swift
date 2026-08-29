import XCTest
@testable import MacAssistantKit

final class IpaZsignSignerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        LocalizationSettings.override = .simplifiedChinese
    }

    func testCommandArgumentsMatchLoadControllerOrder() {
        let args = IpaZsignSigner.commandArguments(
            input: URL(fileURLWithPath: "/tmp/in.ipa"),
            p12URL: URL(fileURLWithPath: "/tmp/cert.p12"),
            p12Password: "secret",
            provisionURL: URL(fileURLWithPath: "/tmp/app.mobileprovision"),
            outputIPA: URL(fileURLWithPath: "/tmp/out.ipa"),
            bundleIDOverride: "com.demo.app",
            bundleNameOverride: "Demo",
            bundleVersionOverride: "1.0"
        )
        XCTAssertEqual(args, [
            "-k", "/tmp/cert.p12",
            "-m", "/tmp/app.mobileprovision",
            "-p", "secret",
            "-z", "1",
            "-o", "/tmp/out.ipa",
            "-b", "com.demo.app",
            "-n", "Demo",
            "-r", "1.0",
            "/tmp/in.ipa"
        ])
        XCTAssertFalse(args.contains("-f"))
    }

    func testInPlaceSignOmitsOutputFlag() {
        let args = IpaZsignSigner.commandArguments(
            input: URL(fileURLWithPath: "/tmp/App.app"),
            p12URL: URL(fileURLWithPath: "/tmp/c.p12"),
            p12Password: "",
            provisionURL: URL(fileURLWithPath: "/tmp/p.mobileprovision")
        )
        XCTAssertFalse(args.contains("-o"))
        XCTAssertEqual(args.last, "/tmp/App.app")
    }

    func testPrimaryProvisionPrefersMainBundleThenExtra() {
        let main = URL(fileURLWithPath: "/tmp/main.mobileprovision")
        let extra = URL(fileURLWithPath: "/tmp/extra.mobileprovision")
        XCTAssertEqual(
            IpaZsignSigner.primaryProvision(
                profilesByBundleID: [
                    "com.demo.app": main,
                    "com.demo.app.ext": URL(fileURLWithPath: "/tmp/ext.mobileprovision")
                ],
                preferring: "com.demo.app"
            ),
            main
        )
        XCTAssertEqual(
            IpaZsignSigner.primaryProvision(
                profilesByBundleID: [:],
                extraProfiles: [extra]
            ),
            extra
        )
    }

    func testIOSAppBundleDetection() throws {
        let root = try FileSystemHelper.makeTemporaryDirectory(prefix: "zsign-domain")
        defer { try? FileManager.default.removeItem(at: root) }

        let ios = root.appendingPathComponent("Phone.app")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        try writePlist(["LSRequiresIPhoneOS": true, "CFBundleIdentifier": "com.phone"], to: ios)
        XCTAssertTrue(IpaZsignSigner.isIOSAppBundle(ios))

        let mac = root.appendingPathComponent("Mac.app")
        try FileManager.default.createDirectory(
            at: mac.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try writePlist(["CFBundleIdentifier": "com.mac.tool"], to: mac)
        XCTAssertFalse(IpaZsignSigner.isIOSAppBundle(mac))
    }

    func testValidateZsignProfileIgnoresOriginalAppEntitlements() throws {
        let profile = ProfileInfo(
            name: "Dev",
            teamID: "TEAM123",
            appID: "TEAM123.com.example.*",
            expirationDate: Date.distantFuture,
            provisionedDevices: [],
            entitlementsXML: "<plist><dict/></plist>"
        )
        XCTAssertNoThrow(
            try SigningService.validateZsignProfile(
                profile,
                identityName: "Apple Development: Tester (TEAM123)"
            )
        )
        XCTAssertThrowsError(
            try SigningService.validateZsignProfile(
                profile,
                identityName: "Apple Development: Tester (OTHER9)"
            )
        )
    }

    private func writePlist(_ values: [String: Any], to bundle: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
    }
}

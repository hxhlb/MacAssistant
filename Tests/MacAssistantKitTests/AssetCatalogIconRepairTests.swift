import XCTest
@testable import MacAssistantKit

final class AssetCatalogIconRepairTests: XCTestCase {
    func testTargetNamesMatchInjectipaLog() {
        XCTAssertEqual(
            AssetCatalogIconRepair.targetRenditionNames,
            ["AppIcon_1024_dark.png", "AppIcon_1024_tinted.png"]
        )
    }

    func testCatalogURLsFindIOSAndMacLayouts() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "car-urls")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ios = dir.appendingPathComponent("WeChat.app")
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        XCTAssertEqual(AssetCatalogIconRepair.catalogURLs(in: ios), [])

        let iosCar = ios.appendingPathComponent("Assets.car")
        try Data("car".utf8).write(to: iosCar)
        XCTAssertEqual(AssetCatalogIconRepair.catalogURLs(in: ios), [iosCar])

        let mac = dir.appendingPathComponent("MacApp.app")
        let macCar = mac.appendingPathComponent("Contents/Resources/Assets.car")
        try FileManager.default.createDirectory(
            at: macCar.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("car".utf8).write(to: macCar)
        XCTAssertEqual(AssetCatalogIconRepair.catalogURLs(in: mac), [macCar])
    }

    func testMissingCatalogIsNoOp() throws {
        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "car-missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("WeChat.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(try AssetCatalogIconRepair.repair(in: app), [])
    }

    func testContainsTargetRenditionReadsExactNames() {
        var data = Data("AppIcon_1024.png AppIcon@2x.png".utf8)
        XCTAssertEqual(AssetCatalogIconRepair.containsTargetRendition(in: data), [])
        data.append(contentsOf: "AppIcon_1024_dark.png".utf8)
        data.append(contentsOf: "AppIcon_1024_tinted.png".utf8)
        XCTAssertEqual(
            AssetCatalogIconRepair.containsTargetRendition(in: data),
            ["AppIcon_1024_dark.png", "AppIcon_1024_tinted.png"]
        )
    }

    func testRepairRemovesBothWeChatIconPairsWhenCatalogIsPresent() throws {
        let source = weChatCatalogURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("本机没有微信 Assets.car，跳过 CoreUI 删除验证")
        }
        let original = try Data(contentsOf: source)
        XCTAssertEqual(
            AssetCatalogIconRepair.containsTargetRendition(in: original),
            ["AppIcon_1024_dark.png", "AppIcon_1024_tinted.png"]
        )

        let dir = try FileSystemHelper.makeTemporaryDirectory(prefix: "car-wechat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("WeChat.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let catalog = app.appendingPathComponent("Assets.car")
        try FileManager.default.copyItem(at: source, to: catalog)

        let removals = try AssetCatalogIconRepair.repair(in: app)
        XCTAssertEqual(
            removals.map(\.renditionName),
            [
                "AppIcon_1024_dark.png",
                "AppIcon_1024_dark.png",
                "AppIcon_1024_tinted.png",
                "AppIcon_1024_tinted.png"
            ]
        )
        XCTAssertTrue(removals.allSatisfy { $0.catalogFileName == "Assets.car" })

        let repaired = try Data(contentsOf: catalog)
        XCTAssertEqual(AssetCatalogIconRepair.containsTargetRendition(in: repaired), [])
        XCTAssertTrue(repaired.range(of: Data("AppIcon_1024.png".utf8)) != nil)
        XCTAssertLessThan(repaired.count, original.count)
    }

    private func weChatCatalogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("微信/Payload/WeChat.app/Assets.car")
    }
}

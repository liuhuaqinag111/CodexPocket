import XCTest
@testable import CodexPocket

/// 在线升级：版本比较 + 桥接端点。
///
/// 做不到 App AppCoordinator 那种"点一下自动装完"—— 这个包是**未签名**的，
/// iOS 不认。真正一键装要 `itms-services://` + 已签名包 + 含本机 UDID 的
/// 描述文件。所以这里做的是"帮你把包拉到手"，外加把签名链路备好。
final class UpdateTests: XCTestCase {
    func testPackageValidationRejectsHTTPErrorsAndNonZipBodies() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = URL(string: "https://updates.invalid/package.ipa")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let denied = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
        try Data("Unauthorized".utf8).write(to: file)
        XCTAssertFalse(UpdateCheck.validPackage(at: file, response: ok))
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: file)
        XCTAssertFalse(UpdateCheck.validPackage(at: file, response: denied))
        XCTAssertTrue(UpdateCheck.validPackage(at: file, response: ok))
    }
    func testIncompleteVersionTokenDoesNotCrash() {
        XCTAssertNil(UpdateCheck.versionKey("2026-10-13 v"))
        XCTAssertNil(UpdateCheck.versionKey("2026-10-13 v."))
    }

    /// 正常版本标记要比得对。
    func testVersionKeyParses() {
        // 主 * 100 + 次，补零四位（位数固定才能按字符串比大小）。
        XCTAssertEqual(UpdateCheck.versionKey("2026-10-07 v61 不再抢桌面端的会话锁"), "20261007.6100")
        XCTAssertEqual(UpdateCheck.versionKey("2026-10-06 v60 x"), "20261006.6000")
        // 小版本：v69.1 必须比 v69 新、比 v70 旧（以前这里解析成 nil → 归 0，
        // 于是 v69.1 被判成比 v64 还旧，在线升级永远不提示）。
        XCTAssertEqual(UpdateCheck.versionKey("2026-10-08 v69.1 x"), "20261008.6901")
        XCTAssertTrue(UpdateCheck.isNewer(remote: "2026-10-08 v69.1 x",
                                          local: "2026-10-08 v69 y"))
        XCTAssertTrue(UpdateCheck.isNewer(remote: "2026-10-08 v70 x",
                                          local: "2026-10-08 v69.1 y"))
        XCTAssertTrue(UpdateCheck.isNewer(remote: "2026-10-08 v7 x",
                                          local: "2026-10-08 v6 y"))
    }

    /// 日期新的一定算新。
    func testNewerByDate() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "2026-10-08 v1 a", local: "2026-10-07 v99 b"),
                      "日期新的反而算旧 —— 用户升不了级")
    }

    /// 同一天比 v 号。
    func testNewerByBuildNumber() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "2026-10-07 v62 a", local: "2026-10-07 v61 b"))
        XCTAssertFalse(UpdateCheck.isNewer(remote: "2026-10-07 v61 a", local: "2026-10-07 v61 b"),
                       "同一个版本被判成有新版 —— 会一直提示升级")
    }

    func testCurrentBuildIsNewerThanPreviouslyShippedV64() {
        XCTAssertTrue(UpdateCheck.isNewer(
            remote: Build.stamp,
            local: "2026-10-08 v64 界面与稳定性优化"))
    }

    /// 解析不出来时**宁可提示**：卡在旧版上的代价比多提示一次大得多。
    func testUnparsableFallsBackToPrompt() {
        XCTAssertTrue(UpdateCheck.isNewer(remote: "乱写的东西", local: "2026-10-07 v61 x"),
                      "解析失败当成'已是最新' —— 用户会一直卡在旧版")
        XCTAssertFalse(UpdateCheck.isNewer(remote: "乱写的东西", local: "乱写的东西"),
                       "两边一样还提示升级")
    }

    /// 桥接要有 /version，App 才知道有没有新版。
    func testBridgeExposesVersion() throws {
        let src = try String(contentsOfFile: TestSource.path("bridge/bridge.mjs"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("'/version'"), "桥接没有 /version")
        XCTAssertTrue(src.contains(".version"), "/version 没读版本文件")
    }

    /// 桥接要有 itms-services 清单端点。
    func testBridgeExposesManifest() throws {
        let src = try String(contentsOfFile: TestSource.path("bridge/bridge.mjs"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("'/manifest'"), "桥接没有 /manifest")
        XCTAssertTrue(src.contains("software-package"),
                      "清单里缺 software-package —— iOS 装不了")
    }

    /// 打包脚本要写版本文件（/version 的数据来源）。
    func testPackScriptWritesVersionFile() throws {
        let src = try TestSource.optionalBuildScript("work/mkipa.sh")
        XCTAssertTrue(src.contains("CodexPocket.ipa.version"),
                      "打包没写版本文件 —— /version 会一直报空")
    }

    func testShipPublishesIPAToBridgeSourceAndVerifiesDownloadedFile() throws {
        let src = try TestSource.optionalBuildScript("work/ship.sh")
        XCTAssertTrue(src.contains("PHONE_DIR=\"${PHONE_DIR:-$HOME/.codex/phone}\""),
                      "发布脚本没有使用桥接目录")
        XCTAssertTrue(src.contains("cp outputs/CodexPocket.ipa \"$PHONE_DIR/CodexPocket.ipa.next\"")
                      && src.contains("mv \"$PHONE_DIR/CodexPocket.ipa.next\" \"$PHONE_DIR/CodexPocket.ipa\""),
                      "发布脚本没有更新桥接实际读取的 IPA")
        XCTAssertTrue(src.contains("cp outputs/CodexPocket.ipa.version \"$PHONE_DIR/CodexPocket.ipa.version.next\"")
                      && src.contains("mv \"$PHONE_DIR/CodexPocket.ipa.version.next\" \"$PHONE_DIR/CodexPocket.ipa.version\""),
                      "发布脚本没有更新桥接版本标记")
        XCTAssertTrue(src.contains("LOCAL_SHA") && src.contains("REMOTE_SHA"),
                      "发布脚本没有验证公网下载包与本地包一致")
    }

    /// 签名脚本要在（一键安装的前提），且**必须显式要 TEAM**。
    func testSignScriptExistsAndDemandsTeam() throws {
        let src = try TestSource.optionalBuildScript("work/sign_ipa.sh")
        XCTAssertTrue(src.contains("TEAM"), "签名脚本没要 TEAM")
        XCTAssertTrue(src.contains("-allowProvisioningUpdates"),
                      "没开自动描述文件 —— 每次都要手动建 profile")
    }
}

import XCTest
@testable import CodexPocket

/// 隐私用途说明。
///
/// 用户报的："一点拍照就闪退"。根因就是 Info.plist 里没有
/// `NSCameraUsageDescription` —— iOS 会**直接杀掉进程**，不是弹窗拒绝，
/// 所以表现是"闪退"，没有任何提示，日志里也看不到业务错误。
/// 相册读权限（`NSPhotoLibraryUsageDescription`）同理。
///
/// 这类 bug 只有"打包时少一个 key"这一种形态，编译和单测都发现不了，
/// 所以专门盯住它。
final class InfoPlistTests: XCTestCase {

    /// **必须读 `Bundle.main`**：单测跑在宿主 App 里，`Bundle.main` 才是
    /// CodexPocket.app；`Bundle(for: type(of: self))` 拿到的是
    /// CodexPocketTests.xctest —— 那里根本没有这些 key，会一直假红。
    private func info() throws -> [String: Any] {
        let b = Bundle.main
        let id = b.bundleIdentifier ?? ""
        try XCTSkipUnless(id == "app.codexpocket.ios",
                          "当前宿主不是 CodexPocket.app（\(id)），读不到 App 的 Info.plist")
        return b.infoDictionary ?? [:]
    }

    func testCameraUsageDescription() throws {
        let v = try info()["NSCameraUsageDescription"] as? String
        XCTAssertNotNil(v, "缺 NSCameraUsageDescription，点拍照必闪退")
        XCTAssertFalse(v?.isEmpty ?? true)
    }

    func testPhotoLibraryUsageDescription() throws {
        let v = try info()["NSPhotoLibraryUsageDescription"] as? String
        XCTAssertNotNil(v, "缺 NSPhotoLibraryUsageDescription，选相册会闪退")
        XCTAssertFalse(v?.isEmpty ?? true)
    }

    func testPhotoLibraryAddUsageDescription() throws {
        XCTAssertNotNil(try info()["NSPhotoLibraryAddUsageDescription"] as? String,
                        "存图到相册需要这个 key")
    }

    func testMicrophoneAndSpeech() throws {
        let d = try info()
        XCTAssertNotNil(d["NSMicrophoneUsageDescription"] as? String)
        XCTAssertNotNil(d["NSSpeechRecognitionUsageDescription"] as? String)
    }
}

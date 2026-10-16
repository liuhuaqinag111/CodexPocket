import XCTest
@testable import CodexPocket

/// 用真桥接量出来的事实，写成回归锁。
///
/// 2026-10-14（真桥接 62113 + 真服务端，脚本
/// `work/award-v70/desktop-steer-effect.mjs`、`steer-reaches-model.mjs`）：
///
///   1. 桌面端起着的回合，**写者锁在桌面进程手里**：
///      `thread/resume` 回 `already has an active writer`。
///   2. 同一个回合，手机端 `turn/steer` **成功**，插话那句进模型 ——
///      最终答复按插话从「收到」改成了「插话到了」。
///   3. 没插话的那次对照（同参数、不 steer）：答复里没有插话内容。
///
/// 所以「电脑端占着 → 插话做不到 → 直接排队」这条老前提是错的，
/// 代价正是用户报的「切回来显示排队而不是插话」。
@MainActor
final class DesktopSteerWorksTests: XCTestCase {

    private func store() -> (AppCoordinator, RecordingTransport) {
        let transport = RecordingTransport()
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), namespace: "desktop-steer-works")
        let s = AppCoordinator(transport: transport, cache: cache)
        s.list.currentID = "t1"
        s.chat.busy = true
        s.chat.desktopLocked = true
        s.chat.localTurn = false
        s.chat.serverTurnId = "turn-desktop"
        return (s, transport)
    }

    /// 电脑端占着、也真有回合在跑：发送键必须是**插话**，不是排队。
    func testDesktopOwnedTurnOffersSteer() {
        let (s, _) = store()
        defer { s.chat.close() }
        s.composer.text = "插一句"
        XCTAssertEqual(s.composer.action, .steer,
                       "电脑端跑着的时候应该能给插话")
    }

    /// 点下去走 `turn/steer`，不能预先降级成排队。
    func testDesktopOwnedTurnSendsSteer() async {
        let (s, transport) = store()
        defer { s.chat.close() }
        s.chat.steer("插一句", localID: "local-desk")
        for _ in 0..<30 { await Task.yield() }
        let calls = transport.calls.map(\.0)
        XCTAssertTrue(calls.contains("turn/steer"), "没走插话：\(calls)")
        XCTAssertFalse(calls.contains("thread/queue/add"), "又降级成排队了：\(calls)")
    }

    /// 回合 id 还不知道（刚切回来 / 刚重启）：也要给插话 ——
    /// `steer()` 会先问一次 `thread/turns/list`。
    func testUnknownTurnIdStillOffersSteer() {
        let (s, _) = store()
        defer { s.chat.close() }
        s.chat.serverTurnId = nil
        s.composer.text = "插一句"
        XCTAssertEqual(s.composer.action, .steer,
                       "回合 id 未知时不该给排队（用户报的「切回来还是排队」）")
    }
}

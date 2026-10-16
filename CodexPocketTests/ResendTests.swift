import XCTest
import Combine
@testable import CodexPocket

/// 「没发出去 · 点这里重试」这条路。
///
/// 用户报的：给旧会话发消息显示"没发出去"，点了几次重试就出来几条
/// 一模一样的消息。两个 bug：
///   1. 重试调 `send(text)` —— **又新增一条**，点 4 次就 4 条。
///   2. 断线时 `failWaiters` 把已经送达的 turn/start 判成失败，
///      消息其实执行完了（通知都发了），界面还写着"没发出去"。
final class ResendTests: XCTestCase {

    @MainActor
    func testStopBeforeTurnIdIsRemembered() {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-starting"
        store.chat.busy = true
        store.chat.localTurn = true
        XCTAssertTrue(store.chat.canStop)
        store.chat.interrupt()
        XCTAssertTrue(store.chat.stopRequested)
        XCTAssertTrue(store.chat.busy)
    }

    @MainActor
    func testOldStopReplyCannotAffectReopenedThread() async {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-A"
        store.chat.serverTurnId = "old"
        let stale = expectation(description: "stale stop banner")
        stale.isInverted = true
        let observation = store.chat.$banner.compactMap { $0 }.sink { _ in stale.fulfill() }
        defer { observation.cancel() }
        store.chat.interrupt()
        store.chat.close()
        store.list.currentID = "synthetic-A"
        store.chat.serverTurnId = "new"
        store.chat.busy = true
        await fulfillment(of: [stale], timeout: 0.1)
        XCTAssertEqual(store.chat.serverTurnId, "new")
        XCTAssertTrue(store.chat.busy)
    }

    @MainActor
    func testCloseClearsTurnAndSendState() {
        let store = AppCoordinator()
        let chat = store.chat
        store.list.currentID = "synthetic-A"
        chat.busy = true
        chat.localTurn = true
        chat.serverTurnId = "turn-A"
        chat.pendingSend = ("local-A", "A")
        chat.failed = ["local-A"]
        chat.sendStates["local-A"] = .failed("offline")
        chat.loadingOlder = true
        chat.close()
        XCTAssertFalse(chat.busy)
        XCTAssertFalse(chat.canStop)
        XCTAssertNil(chat.pendingSend)
        XCTAssertTrue(chat.failed.isEmpty)
        XCTAssertTrue(chat.sendStates.isEmpty)
        XCTAssertFalse(chat.loadingOlder)
    }

    @MainActor
    func testFailedStopLookupKeepsRunningState() async {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-stop"
        store.chat.busy = true
        let done = expectation(description: "stop lookup failure handled")
        let observation = store.chat.$banner.compactMap { $0 }.sink { _ in done.fulfill() }
        defer { observation.cancel() }
        store.chat.interrupt()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(store.chat.busy)
        XCTAssertTrue(store.chat.banner?.hasPrefix("停止失败") == true)
    }

    /// `retry` 必须**原地重跑**，不能再加一条用户消息。
    ///
    /// 上一版 retry 走的是 `send(text)`，条数会从 1 涨到 2；
    /// 用户点 4 次就是 4 条重复气泡（截图里就是这个）。
    @MainActor
    func testRetryReusesBubble() {
        let store = AppCoordinator()
        // 用不存在的会话 id：turn/start 会失败，但我们要验的是
        // items 的增删，不该真去调模型。
        store.list.currentID = "00000000-0000-4000-8000-000000000002"
        store.chat.items = [.user(id: "L1", text: "只回复：好", images: [])]
        store.chat.failed = ["L1"]

        store.chat.retry("L1", text: "只回复：好")

        XCTAssertEqual(users(store), 1, "retry 新增了气泡（会变成几条重复消息）")
        XCTAssertFalse(store.chat.failed.contains("L1"), "retry 没清掉失败标记")
    }

    /// 没有当前会话时 retry 不能改列表、也不能清失败标记。
    @MainActor
    func testRetryWithoutThreadIsNoop() {
        let store = AppCoordinator()
        store.list.currentID = nil
        store.chat.items = [.user(id: "L1", text: "只回复：好", images: [])]
        store.chat.failed = ["L1"]

        store.chat.retry("L1", text: "只回复：好")

        XCTAssertEqual(users(store), 1, "retry 在无会话时改了列表")
        XCTAssertTrue(store.chat.failed.contains("L1"), "retry 不该清掉失败标记")
    }

    @MainActor
    private func users(_ s: AppCoordinator) -> Int {
        s.chat.items.filter {
            if case .user = $0 { return true }
            return false
        }.count
    }
}

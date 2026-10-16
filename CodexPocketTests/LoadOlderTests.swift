import XCTest
import Combine
@testable import CodexPocket

/// 「加载更早的消息」。
///
/// `hasOlder` 以前只被赋值、从来没被读过 —— 长会话永远只能看到最近
/// 12 条，往上滑什么都没有。用户说的"一直获取不完整"就是这个。
final class LoadOlderTests: XCTestCase {

    @MainActor
    func testFailedLoadOlderCanBeRetried() async {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-history"
        store.chat.hasOlder = true
        let done = expectation(description: "history failure handled")
        let observation = store.chat.$loadingOlder.dropFirst().filter { !$0 }.sink { _ in done.fulfill() }
        defer { observation.cancel() }
        store.chat.loadOlder()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(store.chat.loadingOlder)
    }

    func testPaginationUsesTurnsAndCursor() {
        let turn: JSONDict = ["items": Array(repeating: ["id": "item"], count: 50)]
        XCTAssertFalse(ConversationModel.hasMoreTurns(["data": [turn]], limit: 12))
        XCTAssertTrue(ConversationModel.hasMoreTurns(["data": [turn], "nextCursor": "next"], limit: 12))
        XCTAssertFalse(ConversationModel.hasMoreTurns(["data": [turn], "nextCursor": NSNull()], limit: 1))
        XCTAssertTrue(ConversationModel.hasMoreTurns(["data": [turn]], limit: 1))
    }

    /// 没有更早的消息时不该去拉。
    @MainActor
    func testLoadOlderIsNoopWhenNoMore() {
        let store = AppCoordinator()
        store.list.currentID = "T1"
        store.chat.hasOlder = false
        let before = store.chat.loadedTurns

        store.chat.loadOlder()

        XCTAssertEqual(store.chat.loadedTurns, before, "明明没有更早的还去加载")
        XCTAssertFalse(store.chat.loadingOlder, "不该进加载中状态")
    }

    /// 有更早的消息时要真的把窗口撑大。
    @MainActor
    func testLoadOlderGrowsWindow() {
        let store = AppCoordinator()
        store.list.currentID = "T1"
        store.chat.hasOlder = true
        let before = store.chat.loadedTurns
        XCTAssertEqual(before, ConversationModel.firstPage, "初始窗口不对")

        store.chat.loadOlder()

        XCTAssertGreaterThan(store.chat.loadedTurns, before,
                             "点了加载更早但窗口没变大")
        XCTAssertTrue(store.chat.loadingOlder, "没进加载中状态")
    }

    /// 没有当前会话时不该动。
    @MainActor
    func testLoadOlderNeedsCurrentThread() {
        let store = AppCoordinator()
        store.list.currentID = nil
        store.chat.hasOlder = true
        let before = store.chat.loadedTurns

        store.chat.loadOlder()

        XCTAssertEqual(store.chat.loadedTurns, before, "没有会话也去加载了")
    }
}

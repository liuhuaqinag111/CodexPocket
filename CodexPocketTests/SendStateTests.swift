import XCTest
@testable import CodexPocket

/// 发送状态行什么时候出现。
///
/// 用户抱怨的："一发消息就显示已排队投递电脑端正在占用此会话" ——
/// 一句全局 banner，把 0.2 秒的事说得很重，而且跟"排队"没关系。
///
/// 规则（照 Happy 的 `PENDING_STATUS_GRACE_MS = 1_000`）：
///   忙碌排队 → 立刻显示
///   空闲发送 → 1 秒内静默，超过才显示
///   失败     → 立刻显示
final class SendStateTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 空闲发送 0.3 秒：**什么都不该显示**。
    func testFreshSendingIsSilent() {
        let s = SendState.sending(since: t0)
        XCTAssertFalse(SendStatusLine.shouldShow(s, now: t0.addingTimeInterval(0.3)),
                       "刚发出去就报状态 —— 0.2 秒的事被说得很重")
    }

    /// 空闲发送超过 1 秒：显示"发送中…"。
    func testSlowSendingShows() {
        let s = SendState.sending(since: t0)
        XCTAssertTrue(SendStatusLine.shouldShow(s, now: t0.addingTimeInterval(1.2)))
        XCTAssertEqual(SendStatusLine.text(s), "发送中…")
    }

    /// 排队：**立刻**显示（这条确实要等）。
    func testQueuedShowsImmediately() {
        let s = SendState.queued(since: t0)
        XCTAssertTrue(SendStatusLine.shouldShow(s, now: t0),
                      "排队要立刻说清楚，否则用户以为消息丢了")
        XCTAssertEqual(SendStatusLine.text(s), "已排队，尚未发送")
    }

    /// 失败：立刻显示，带原因。
    func testFailedShowsImmediatelyWithReason() {
        let s = SendState.failed("连接中断")
        XCTAssertTrue(SendStatusLine.shouldShow(s, now: t0))
        XCTAssertEqual(SendStatusLine.text(s), "没发出去：连接中断")
    }

    /// 没有状态 → 不显示。
    func testNilIsHidden() {
        XCTAssertFalse(SendStatusLine.shouldShow(nil, now: t0))
    }

    /// 宽限期是 1 秒（别被改小）。
    func testGraceIsOneSecond() {
        XCTAssertEqual(SendStatusLine.grace, 1)
    }

    /// `fail` 不能再改气泡本身的样式 —— 改样式会重排，用户看到界面抖一下。
    @MainActor
    func testFailDoesNotRestyleBubble() {
        let store = AppCoordinator()
        store.chat.items = [.user(id: "L1", text: "你好", images: [])]
        store.chat.fail("L1", "连接中断")
        // 条目本身必须**原样不动**。
        XCTAssertEqual(store.chat.items.first, .user(id: "L1", text: "你好", images: []),
                       "失败时改了气泡内容，会导致重排闪烁")
        XCTAssertEqual(store.chat.sendStates["L1"], .failed("连接中断"))
    }

    /// 服务端接受后状态要清掉。
    @MainActor
    func testAcceptClearsState() {
        let store = AppCoordinator()
        store.chat.items = [.user(id: "L1", text: "你好", images: [])]
        store.chat.fail("L1", "连接中断")
        store.chat.accept("L1")
        XCTAssertNil(store.chat.sendStates["L1"])
        XCTAssertFalse(store.chat.failed.contains("L1"))
    }
}

import XCTest
@testable import CodexPocket

/// 轮询要跟着"当前打开的会话"走。
///
/// 以前 `startRemoteWatch` 是 `guard remoteTimer == nil else { return }`，
/// 定时器闭包里捕获的是**第一次**那个 id —— 于是只有第一个打开的会话
/// 会被轮询，之后切过去的会话永远收不到电脑端的更新。
/// 表现就是用户报的"电脑发的消息我手机版看不到"，而且是**第二个**会话才犯。
final class RemoteWatchTests: XCTestCase {

    @MainActor
    func testWatchFollowsCurrentThread() {
        let store = AppCoordinator()

        store.chat.startRemoteWatch("thread-A")
        XCTAssertEqual(store.chat.remoteWatching, "thread-A")

        // 切到另一个会话 —— 轮询必须跟过去。
        store.chat.startRemoteWatch("thread-B")
        XCTAssertEqual(store.chat.remoteWatching, "thread-B",
                       "切了会话但轮询还盯着旧的，新会话收不到电脑端更新")

        // 同一个会话重复调用不该重建（省得每 2.5 秒的定时器被反复重置）。
        let before = store.chat.remoteTimer
        store.chat.startRemoteWatch("thread-B")
        XCTAssertTrue(before === store.chat.remoteTimer, "同一个会话被重复重建了定时器")
    }

    @MainActor
    func testStopClearsTarget() {
        let store = AppCoordinator()
        store.chat.startRemoteWatch("thread-A")
        store.chat.stopRemoteWatch()
        XCTAssertNil(store.chat.remoteWatching, "stop 之后还盯着旧会话")
        XCTAssertNil(store.chat.remoteTimer)
    }
}

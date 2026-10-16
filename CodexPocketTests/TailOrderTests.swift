import XCTest
@testable import CodexPocket

/// 「我发的消息跑到回复下面去了」。
///
/// 复现路径（用户报的）：发一条消息 → 收到回复 → 自己那条**掉到最底下**。
///
/// 根因在 `mergeTail`：它把服务端回合里**没见过的**条目一律 append 到末尾。
/// 本地那条乐观插入的用户消息是 `local-…`，服务端的是另一个 id，
/// 于是"删掉本地的 + 把服务端的追加到末尾" = 用户消息跑到回复下面。
final class TailOrderTests: XCTestCase {

    /// 本地刚发完：分隔线 → 用户消息 → 分隔线 → 助手回复。
    @MainActor
    private func localAfterSend() -> AppCoordinator {
        let store = AppCoordinator()
        store.chat.items = [
            .turnBreak(id: "tb-local", at: Date(), duration: nil),
            .user(id: "local-1", text: "你好", images: []),
            .turnBreak(id: "tb-T1", at: Date(), duration: nil),
            .agent(id: "a1", text: "好"),
        ]
        return store
    }

    /// 服务端最新一个回合（轮询拿回来的那一段）。
    private var serverTail: [Item] {
        [Protocol_.item(from: ["type": "userMessage", "id": "u1", "clientId": "local-1",
             "content": [["type": "text", "text": "你好"]]])!,
         .agent(id: "a1", text: "好"),
         .turnBreak(id: "tb-T1", at: Date(), duration: 3)]
    }

    /// 用户消息必须**在回复之前**。
    @MainActor
    func testUserStaysAboveReply() {
        let store = localAfterSend()
        store.chat.mergeTail(serverTail)
        let ids = store.chat.items.map { $0.id }
        guard let ui = ids.firstIndex(of: "local-1"), let ai = ids.firstIndex(of: "a1") else {
            return XCTFail("合并后缺条目：\(ids)")
        }
        XCTAssertLessThan(ui, ai, "我发的消息跑到回复下面了")
    }

    /// 合并之后不能冒出两条一样的用户消息。
    @MainActor
    func testNoDuplicateUserBubble() {
        let store = localAfterSend()
        store.chat.mergeTail(serverTail)
        let users = store.chat.items.filter { if case .user = $0 { return true }; return false }
        XCTAssertEqual(users.count, 1, "同一条用户消息出现了两次")
        XCTAssertEqual(users.first?.id, "local-1", "服务端回显沿用客户端提交身份")
    }

    /// 回复本身不能因此丢。
    @MainActor
    func testReplySurvives() {
        let store = localAfterSend()
        store.chat.mergeTail(serverTail)
        XCTAssertTrue(store.chat.items.contains { $0.id == "a1" })
    }
}

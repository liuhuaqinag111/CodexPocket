import XCTest
@testable import CodexPocket

/// `mergeTail`：把服务端最新的回合并进本地列表。
///
/// 它以前**无条件**删掉最后一条本地乐观插入的消息（`local-` 前缀）。
/// 碰上"还没送达"的消息，就把它从界面上抹掉了 —— 用户看到自己刚发的
/// 话凭空消失。只有服务端确实带来了用户消息时才该去重。
final class MergeTailTests: XCTestCase {

    @MainActor
    func testHistoryDoesNotDeleteUnrelatedPendingMessage() {
        let chat = AppCoordinator().chat
        chat.items = [.user(id: "local-new", text: "new", images: [])]
        chat.mergeTail([.user(id: "old", text: "old", images: [])])
        XCTAssertTrue(chat.items.contains { $0.id == "local-new" })
    }

    @MainActor
    func testKnownEchoDoesNotConsumeRepeatedNewMessage() {
        let chat = AppCoordinator().chat
        chat.items = [.user(id: "old", text: "again", images: []),
                      .user(id: "local-new", text: "again", images: [])]
        chat.mergeTail([.user(id: "old", text: "again", images: [])])
        XCTAssertEqual(chat.items.map(\.id), ["old", "local-new"])
    }

    @MainActor
    func testFullHistoryCannotShortenStreamedAnswer() {
        let chat = AppCoordinator().chat
        chat.items = [.agent(id: "a", text: "complete answer")]
        chat.mergeTail([.agent(id: "a", text: "complete")])
        XCTAssertEqual(chat.items.first?.text, "complete answer")
    }

    /// 服务端没带来用户消息时，本地那条必须留着。
    @MainActor
    func testKeepsLocalMessageWhenServerHasNoUserMessage() {
        let store = AppCoordinator()
        store.chat.items = [.user(id: "local-1", text: "还没送达", images: [])]

        // 服务端只回了一条助手消息（说明用户那条没到）。
        store.chat.mergeTail([.agent(id: "a1", text: "回复")])

        let kept = store.chat.items.contains {
            if case .user(let i, _, _) = $0 { return i == "local-1" }
            return false
        }
        XCTAssertTrue(kept, "本地那条没送达的消息被 mergeTail 删掉了")
    }

    /// 服务端回显相同 clientId 时只保留一条，并完成待发状态。
    @MainActor
    func testStableClientEchoResolvesPendingMessage() throws {
        let store = AppCoordinator()
        store.chat.items = [.user(id: "local-1", text: "你好", images: [])]
        store.chat.markSending("local-1")
        let echo = try XCTUnwrap(Protocol_.item(from: ["type": "userMessage", "id": "u1",
            "clientId": "local-1", "content": [["type": "text", "text": "你好"]]]))
        store.chat.mergeTail([
            echo,
            .agent(id: "a1", text: "回复"),
        ])

        XCTAssertEqual(store.chat.items.filter { if case .user = $0 { return true }; return false }.map(\.id), ["local-1"])
        XCTAssertNil(store.chat.sendStates["local-1"])
        XCTAssertEqual(store.chat.items.count, 2, "去重后应该正好两条")
    }
}

/// 「发一条消息，界面出现两条一样的」。
///
/// 服务端回读的用户消息**带尾换行**（真实样本：`"…还卡死了\n"`），
/// 本地那条是输入框 trim 过的。以前按 `==` 比，匹配不上 ——
/// 本地气泡替换不掉，服务端那份又插进列表，界面上就是两条一模一样的。
final class DuplicateEchoTests: XCTestCase {

    @MainActor
    func testServerEchoWithTrailingNewlineReplacesLocalBubble() throws {
        let chat = AppCoordinator().chat
        chat.items = [.user(id: "local-1", text: "你好", images: [])]
        let echo = try XCTUnwrap(Protocol_.item(from: ["type": "userMessage", "id": "srv-1",
            "clientId": "local-1", "content": [["type": "text", "text": "你好\n"]]]))
        chat.mergeTail([echo])
        XCTAssertEqual(chat.items.count, 1, "服务端回显又插了一条，界面上会有两条一样的")
        XCTAssertEqual(chat.items.first?.id, "local-1", "回显保留客户端身份")
        XCTAssertEqual(chat.items.first?.text, "你好\n")
    }

    @MainActor
    func testServerEchoWithLeadingSpaceAlsoMatches() throws {
        let chat = AppCoordinator().chat
        chat.items = [.user(id: "local-2", text: "看一下", images: [])]
        let echo = try XCTUnwrap(Protocol_.item(from: ["type": "userMessage", "id": "srv-2",
            "clientId": "local-2", "content": [["type": "text", "text": "  看一下 \n"]]]))
        chat.mergeTail([echo])
        XCTAssertEqual(chat.items.count, 1)
        XCTAssertEqual(chat.items.first?.id, "local-2")
    }

    @MainActor
    func testDifferentTextStillAppends() {
        let chat = AppCoordinator().chat
        chat.items = [.user(id: "local-3", text: "甲", images: [])]
        chat.mergeTail([.user(id: "srv-3", text: "乙", images: [])])
        XCTAssertEqual(chat.items.count, 2, "不是同一句就不能吞掉")
    }

    func testSameTextIgnoresSurroundingWhitespace() {
        XCTAssertTrue(ConversationModel.sameText("你好", "你好\n"))
        XCTAssertTrue(ConversationModel.sameText(" 你好 ", "你好"))
        XCTAssertFalse(ConversationModel.sameText("你好", "你好吗"))
    }
}

import XCTest
@testable import CodexPocket

/// 「这条消息到底送达没有」的判定。
///
/// 断线时 `turn/start` / `turn/steer` 的回包都会丢，但服务端往往已经
/// 收到了。凭回包判断会误判成失败 —— 用户一点重试，同一句话就执行两遍。
/// 所以判定要看服务端有没有这条用户消息。
final class DeliveredTests: XCTestCase {
    @MainActor
    func testOldIdenticalTextDoesNotConfirmNewSubmission() async {
        let transport = RecordingTransport()
        transport.result = .success(["data": [["id": "old-turn", "items": [
            ["id": "old-user", "type": "userMessage", "clientId": "old-client",
             "content": [["type": "text", "text": "hi"]]]]]]] as JSONDict)
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.items = [.user(id: "old-user", text: "hi", images: []),
                            .user(id: "local-new", text: "hi", images: [])]
        store.chat.markSending("local-new")
        store.chat.pendingSend = (id: "local-new", text: "hi")
        store.chat.confirmPending()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.chat.items.contains { $0.id == "local-new" })
        XCTAssertFalse(store.chat.failed.contains("local-new"), "只读历史里没匹配身份，不能证明未发送")
        XCTAssertEqual(store.chat.pendingSend?.id, "local-new")
        XCTAssertEqual(store.chat.sendStates["local-new"], .confirming)
        XCTAssertFalse(transport.calls.contains { $0.0 == "turn/start" })
        store.chat.close()
    }

    /// 服务端回合里有同样文本的用户消息 → 算送达。
    func testFindsDeliveredMessage() {
        let items: [Item] = [
            .user(id: "u1", text: "只回复：好", images: []),
            .agent(id: "a1", text: "好"),
        ]
        XCTAssertTrue(ConversationModel.containsUser("只回复：好", in: items))
    }

    /// 服务端还没有这条 → 没送达（这时候重发才是安全的）。
    func testMissingMessageIsNotDelivered() {
        let items: [Item] = [
            .user(id: "u1", text: "别的话", images: []),
            .agent(id: "a1", text: "好"),
        ]
        XCTAssertFalse(ConversationModel.containsUser("只回复：好", in: items))
    }

    /// 前后空白不该影响判定 —— 输入框里很容易多带一个空格或换行，
    /// 那样就会被判成"没送达"，进而重复执行。
    func testIgnoresSurroundingWhitespace() {
        let items: [Item] = [.user(id: "u1", text: "  只回复：好\n", images: [])]
        XCTAssertTrue(ConversationModel.containsUser("只回复：好", in: items))
        XCTAssertTrue(ConversationModel.containsUser("  只回复：好  ", in: items))
    }

    /// 只有助手消息、没有用户消息时，不能误判成送达。
    func testAgentOnlyIsNotDelivered() {
        let items: [Item] = [.agent(id: "a1", text: "只回复：好")]
        XCTAssertFalse(ConversationModel.containsUser("只回复：好", in: items),
                       "助手消息不该被当成用户消息")
    }

    /// 空列表不算送达。
    func testEmptyIsNotDelivered() {
        XCTAssertFalse(ConversationModel.containsUser("只回复：好", in: []))
    }
}

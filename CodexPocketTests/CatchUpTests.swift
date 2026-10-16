import XCTest
@testable import CodexPocket

/// 断线 / 切后台回来之后的内容补拉。
///
/// 用户报的：「我发完消息切后台，回复完了再切回来，看不见回复内容」。
/// 根因是进入会话时那条流式占位 id 从没跟服务端的真实 item id 对齐过，
/// SwiftUI 的 ForEach 认 id 不认内容 —— 补拉了也渲染不出来。
final class CatchUpTests: XCTestCase {
    private func items(_ pairs: [(String, String)]) -> [Item] {
        pairs.map { .agent(id: $0.0, text: $0.1) }
    }

    func testPlaceholderIdIsRealigned() {
        let local = items([("item/agentMessage/delta-abc", "答完了")])
        let out = ConversationModel.alignAgentIds(local, realIds: ["item-95", "item-97"])
        XCTAssertEqual(out.last?.id, "item-97", "末尾占位 id 没换成服务端真实 id")
        XCTAssertEqual(out.last?.text, "答完了", "对齐 id 时把正文弄丢了")
    }

    func testAlreadyRealIsUntouched() {
        let local = items([("item-97", "答完了")])
        let out = ConversationModel.alignAgentIds(local, realIds: ["item-95", "item-97"])
        XCTAssertEqual(out.last?.id, "item-97")
    }

    func testEmptyRealIdsIsNoop() {
        let local = items([("item/agentMessage/delta-abc", "答完了")])
        let out = ConversationModel.alignAgentIds(local, realIds: [])
        XCTAssertEqual(out.last?.id, "item/agentMessage/delta-abc")
    }

    func testEmptyTextIsNotTouched() {
        // 空正文是流式占位，服务端那份才是权威；不在这里改。
        let local = items([("item/agentMessage/delta-abc", "")])
        let out = ConversationModel.alignAgentIds(local, realIds: ["item-97"])
        XCTAssertEqual(out.last?.id, "item/agentMessage/delta-abc")
    }

    func testEarlierMismatchIsNotTouched() {
        // 前面那条 id 对不上，但末尾是对的 → 一条都不动。
        let local = items([("weird-1", "旧内容"), ("item-97", "新内容")])
        let out = ConversationModel.alignAgentIds(local, realIds: ["item-97"])
        XCTAssertEqual(out[0].id, "weird-1")
        XCTAssertEqual(out[1].id, "item-97")
    }
}

import XCTest
@testable import CodexPocket

/// 刷新**不能**把过程条目丢掉。
///
/// 实测（同一个跑完的回合，直连 app-server 量的）：
///
///   thread/turns/list 不带 itemsView → items=2  bytes=1055  userMessage,agentMessage
///   thread/turns/list itemsView=full → items=6  bytes=3359  userMessage,reasoning,
///                                                            commandExecution,reasoning,
///                                                            commandExecution,agentMessage
///
/// 服务端默认给的是 `summary` 视图，它把 reasoning / commandExecution /
/// fileChange 这类**整条丢掉**。所以 `reload()` / `catchUp()` 一律不能用
/// 服务端那一份整体替换本地列表 —— 那等于每次刷新都抹掉屏幕上的思考过程和
/// 命令输出（用户报的"思考过程和命令输出会消失"）。
///
/// 这两条测试锁的就是"服务端少给了东西时本地不能跟着少"。
final class SummaryLossTests: XCTestCase {

    /// 服务端 summary 只回了正文，本地那份思考/命令必须留着。
    @MainActor
    func testServerSummaryDoesNotDropLocalProcessItems() {
        let store = AppCoordinator()
        store.chat.items = [
            .user(id: "u1", text: "写 1200 字", images: []),
            .reasoning(id: "r1", text: "先想一下结构"),
            .command(id: "c1", command: "ls -la /tmp", output: "a.txt"),
            .agent(id: "a1", text: "正文")
        ]

        // 服务端 summary 只给 userMessage + agentMessage。
        store.chat.mergeTail([
            .user(id: "u1", text: "写 1200 字", images: []),
            .agent(id: "a1", text: "正文")
        ])

        let kinds = store.chat.items.map { it -> String in
            switch it {
            case .user: return "user"
            case .reasoning: return "reasoning"
            case .command: return "command"
            case .agent: return "agent"
            default: return "other"
            }
        }
        XCTAssertTrue(kinds.contains("reasoning"), "思考过程被服务端的 summary 冲掉了")
        XCTAssertTrue(kinds.contains("command"), "命令输出被服务端的 summary 冲掉了")
        XCTAssertEqual(store.chat.items.count, 4, "条数变了，说明被整体替换过")
    }

    /// 正文不许被服务端的旧版本回退。
    func testShorterServerTextDoesNotOverwriteLocal() {
        let local: [Item] = [.agent(id: "a1", text: "已经流式长出来的完整正文")]
        let fresh: [Item] = [.agent(id: "a1", text: "短的")]
        let out = ConversationModel.withoutShorterAgentText(fresh, than: local)
        XCTAssertTrue(out.isEmpty, "服务端更短的正文没被挡住 —— 界面会闪一下变短")
    }

    /// 服务端更长时要用服务端的。
    func testLongerServerTextWins() {
        let local: [Item] = [.agent(id: "a1", text: "短")]
        let fresh: [Item] = [.agent(id: "a1", text: "服务端这份更长更完整")]
        let out = ConversationModel.withoutShorterAgentText(fresh, than: local)
        XCTAssertEqual(out.count, 1, "服务端更完整的那份被挡掉了")
    }

    /// 过程条目不参与长度比较 —— 它们只有服务端有。
    func testProcessItemsAlwaysPass() {
        let local: [Item] = [.agent(id: "a1", text: "很长的一段正文")]
        let fresh: [Item] = [
            .reasoning(id: "r1", text: "想"),
            .command(id: "c1", command: "ls", output: ""),
            .fileChange(id: "f1", changes: [])
        ]
        let out = ConversationModel.withoutShorterAgentText(fresh, than: local)
        XCTAssertEqual(out.count, 3, "过程条目被判掉了")
    }
}

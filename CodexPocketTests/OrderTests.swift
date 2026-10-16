import XCTest
@testable import CodexPocket

/// 用户报的："最后的结论后面为什么还有思考过程"。
///
/// 根因：服务端的流是**按到达顺序**给的，思考摘要经常比正文晚到
/// （`item/reasoning/summaryPartAdded` 跟在 agentMessage 的 delta 后面）。
/// 直接按到达顺序渲染，结论后面就挂着一整段思考。
///
/// 本测试锁住 `Grouping.ordered`：回合内 用户 → 分隔线 → 思考 → 其余。
///
/// 分隔线排在用户消息**之后、思考之前**。不是"回合末尾"：
/// 它其实是下一轮的边界标记，排在末尾会被算进上一轮的折叠组，
/// 耗时也挂错行（实测「1 步 12 秒」挂在上一轮上）。
final class OrderTests: XCTestCase {

    private func kinds(_ items: [Item]) -> [String] {
        Grouping.ordered(items).map { it in
            switch it {
            case .user: return "user"
            case .reasoning: return "reason"
            case .agent: return "agent"
            case .command: return "cmd"
            case .turnBreak: return "break"
            default: return "other"
            }
        }
    }

    /// 思考晚到（在正文之后）→ 必须被提到正文前面。
    func testLateReasoningMovesBeforeConclusion() {
        let items: [Item] = [
            .user(id: "u", text: "问题", images: []),
            .agent(id: "a", text: "结论"),
            .reasoning(id: "r", text: "其实我是这么想的"),
            .turnBreak(id: "tb", at: Date(), duration: 1),
        ]
        XCTAssertEqual(kinds(items), ["user", "break", "reason", "agent"])
    }

    /// 同类的相对顺序不能变（稳定重排）。
    func testRelativeOrderWithinKindIsStable() {
        let items: [Item] = [
            .user(id: "u", text: "问题", images: []),
            .reasoning(id: "r1", text: "一"),
            .command(id: "c1", command: "ls", output: ""),
            .reasoning(id: "r2", text: "二"),
            .agent(id: "a", text: "结论"),
            .turnBreak(id: "tb", at: Date(), duration: 1),
        ]
        XCTAssertEqual(kinds(items), ["user", "break", "reason", "reason", "cmd", "agent"])
    }

    /// 正文里穿插的命令**不能**被挪乱：agent → cmd → agent 保持原样。
    func testInterleavedCommandIsNotReordered() {
        let items: [Item] = [
            .user(id: "u", text: "问题", images: []),
            .agent(id: "a1", text: "先看看"),
            .command(id: "c", command: "ls", output: ""),
            .agent(id: "a2", text: "结论"),
            .turnBreak(id: "tb", at: Date(), duration: 1),
        ]
        XCTAssertEqual(kinds(items), ["user", "break", "agent", "cmd", "agent"])
    }

    /// 跨回合不能串：第二回合的思考不能被提到第一回合去。
    func testTurnsDoNotMix() {
        let items: [Item] = [
            .user(id: "u1", text: "一", images: []),
            .agent(id: "a1", text: "答一"),
            .turnBreak(id: "tb1", at: Date(), duration: 1),
            .user(id: "u2", text: "二", images: []),
            .agent(id: "a2", text: "答二"),
            .reasoning(id: "r2", text: "晚到的思考"),
            .turnBreak(id: "tb2", at: Date(), duration: 1),
        ]
        XCTAssertEqual(kinds(items),
                       ["user", "break", "agent", "user", "break", "reason", "agent"])
    }
}

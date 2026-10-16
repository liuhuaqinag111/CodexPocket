import XCTest
@testable import CodexPocket

/// 继续挖「回复下面还有思考」：试各种真实可能的排布。
final class ReasonOrder2Tests: XCTestCase {

    private func kinds(_ rows: [Grouping.Row]) -> String {
        rows.map { r -> String in
            switch r {
            case .one(let it):
                switch it {
                case .user: return "U"
                case .agent: return "A"
                case .reasoning: return "R"
                case .turnBreak: return "T"
                case .command: return "C"
                case .tool: return "X"
                case .fileChange: return "F"
                case .plan: return "P"
                default: return "o"
                }
            case .work(_, let items, _, _):
                return "W[" + items.map { it -> String in
                    switch it {
                    case .turnBreak: return "T"
                    case .reasoning: return "R"
                    case .command: return "C"
                    case .tool: return "X"
                    case .fileChange: return "F"
                    case .plan: return "P"
                    default: return "o"
                    }
                }.joined() + "]"
            }
        }.joined(separator: " ")
    }

    /// 服务端真实形状：turnBreak 在**末尾**（turn/started 事件晚到）。
    func testTurnBreakAtEnd() {
        let items: [Item] = [
            .user(id: "u1", text: "问", images: []),
            .agent(id: "a1", text: "答"),
            .reasoning(id: "r1", text: "想"),
            .turnBreak(id: "tb-1", at: Date(), duration: 4)
        ]
        print("### tb 在末尾 → " + kinds(Grouping.rows(items, liveTurnId: nil)))
    }

    /// 跨两个回合：上一轮的思考被算进下一轮。
    func testTwoTurns() {
        let items: [Item] = [
            .turnBreak(id: "tb-1", at: Date(), duration: 3),
            .user(id: "u1", text: "第一问", images: []),
            .reasoning(id: "r1", text: "想一"),
            .agent(id: "a1", text: "答一"),
            .turnBreak(id: "tb-2", at: Date(), duration: 4),
            .user(id: "u2", text: "第二问", images: []),
            .agent(id: "a2", text: "答二"),
            .reasoning(id: "r2", text: "想二")
        ]
        print("### 两回合 → " + kinds(Grouping.rows(items, liveTurnId: nil)))
    }

    /// 服务端 items 顺序：agentMessage 先于 reasoning（同回合内）
    func testRealisticServerOrder() {
        let items: [Item] = [
            .turnBreak(id: "tb-1", at: Date(), duration: 4),
            .user(id: "u1", text: "问", images: []),
            .agent(id: "a1", text: "答"),
            .reasoning(id: "r1", text: "想一"),
            .reasoning(id: "r2", text: "想二"),
            .command(id: "c1", command: "ls", output: "")
        ]
        print("### 真实服务端序 → " + kinds(Grouping.rows(items, liveTurnId: nil)))
    }

    /// 只有一条 reasoning 且**没有** turnBreak —— 这时不折叠，平铺。
    func testSingleReasoningNoBreak() {
        let items: [Item] = [
            .user(id: "u1", text: "问", images: []),
            .agent(id: "a1", text: "答"),
            .reasoning(id: "r1", text: "想")
        ]
        print("### 单思考无分隔 → " + kinds(Grouping.rows(items, liveTurnId: nil)))
    }

    /// 思考在**中间**（正常顺序）时不该被动。
    func testReasoningInMiddleUntouched() {
        let items: [Item] = [
            .turnBreak(id: "tb-1", at: Date(), duration: 4),
            .user(id: "u1", text: "问", images: []),
            .reasoning(id: "r1", text: "想"),
            .agent(id: "a1", text: "答")
        ]
        print("### 正常序 → " + kinds(Grouping.rows(items, liveTurnId: nil)))
    }
}

import XCTest
@testable import CodexPocket

/// 「回复下面为什么还有思考」。
///
/// 服务端的流是**按到达顺序**给的：思考摘要经常比正文晚到
/// （`item/reasoning/summaryPartAdded` / `textDelta` 跟在 agentMessage 后面）。
/// 直接按到达顺序渲染，看到的就是结论后面挂着一整段思考。
final class ReasonOrderTests: XCTestCase {

    private func kinds(_ rows: [Grouping.Row]) -> String {
        rows.map { r -> String in
            switch r {
            case .one(let it):
                switch it {
                case .user: return "U"
                case .agent: return "A"
                case .reasoning: return "R"
                case .turnBreak: return "T"
                default: return "o"
                }
            case .work(_, let items, _, _):
                let has = items.contains { if case .reasoning = $0 { return true }; return false }
                return has ? "W(R)" : "W"
            }
        }.joined(separator: " ")
    }

    /// 思考比正文晚到（服务端真实顺序）→ 渲染出来必须在正文前面。
    func testLateReasoningRendersBeforeReply() {
        let items: [Item] = [
            .turnBreak(id: "tb-1", at: Date(), duration: 4),
            .user(id: "u1", text: "写个代码块", images: []),
            .agent(id: "a1", text: "正文"),
            .reasoning(id: "r1", text: "先想一下")   // 晚到
        ]
        let rows = Grouping.rows(items, liveTurnId: nil)
        let out = kinds(rows)
        print("### 晚到思考 → " + out)
        // R 不能在 A 后面
        let seq = out.split(separator: " ").map(String.init)
        let ai = seq.firstIndex { $0 == "A" }
        let ri = seq.firstIndex { $0 == "W(R)" || $0 == "R" }
        XCTAssertNotNil(ai); XCTAssertNotNil(ri)
        XCTAssertLessThan(ri!, ai!, "思考渲染在正文后面了：\(out)")
    }

    /// 同一回合里思考来了两批、都晚到。
    func testTwoLateReasoningBatches() {
        let items: [Item] = [
            .turnBreak(id: "tb-1", at: Date(), duration: 4),
            .user(id: "u1", text: "问", images: []),
            .agent(id: "a1", text: "答"),
            .reasoning(id: "r1", text: "想一"),
            .reasoning(id: "r2", text: "想二")
        ]
        let out = kinds(Grouping.rows(items, liveTurnId: nil))
        print("### 两批晚到 → " + out)
        let seq = out.split(separator: " ").map(String.init)
        let ai = seq.firstIndex { $0 == "A" }!
        let ri = seq.firstIndex { $0 == "W(R)" || $0 == "R" }!
        XCTAssertLessThan(ri, ai, "思考在正文后面：\(out)")
    }

    /// 没有 turnBreak 时也不能乱序。
    func testNoTurnBreakStillOrdered() {
        let items: [Item] = [
            .user(id: "u1", text: "问", images: []),
            .agent(id: "a1", text: "答"),
            .reasoning(id: "r1", text: "想")
        ]
        let out = kinds(Grouping.rows(items, liveTurnId: nil))
        print("### 无分隔线 → " + out)
        let seq = out.split(separator: " ").map(String.init)
        let ai = seq.firstIndex { $0 == "A" }!
        let ri = seq.firstIndex { $0 == "R" }!
        XCTAssertLessThan(ri, ai, "思考在正文后面：\(out)")
    }

    /// 回合进行中：不折叠，但顺序也得对。
    func testLiveTurnOrdered() {
        let items: [Item] = [
            .turnBreak(id: "tb-1", at: Date(), duration: nil),
            .user(id: "u1", text: "问", images: []),
            .agent(id: "a1", text: "答"),
            .reasoning(id: "r1", text: "想")
        ]
        let out = kinds(Grouping.rows(items, liveTurnId: "1"))
        print("### 进行中 → " + out)
        let seq = out.split(separator: " ").map(String.init)
        let ai = seq.firstIndex { $0 == "A" }!
        let ri = seq.firstIndex { $0 == "R" }!
        XCTAssertLessThan(ri, ai, "进行中思考在正文后面：\(out)")
    }
}

import XCTest
@testable import CodexPocket

/// 「回复下面还有思考」。
///
/// 数据是从模拟器里 dump 出来的真实序列（`raw=` 探针）：
///
///   第二轮 raw=U T A R T U T R A
///            tb=017a37:7  245C5E:-1  d7c92e:4
///                          ↑ 时长 -1，从没完成过
///   渲染结果 U W(TR) A U W(TR) A     ← 思考跑到上一轮回复后面
///
/// 两个来源各错一半：
///   1. `items(fromTurn:)` 把分隔线追加在回合末尾，回合还在跑时它落在
///      用户消息正后面 —— 插在回合中间。
///   2. `send()` 插的 `tb-local-` 分隔线永远没人清理。
final class ReasonOrder3Tests: XCTestCase {

    private func kinds(_ rows: [Grouping.Row]) -> String {
        rows.map { r -> String in
            switch r {
            case .one(let it): return Grouping.letter(it)
            case .work(_, let m, _, _): return "W(" + m.map { Grouping.letter($0) }.joined() + ")"
            }
        }.joined()
    }

    /// 实测抓到的坏序列，修完必须渲染成 U W(TR) A U W(TR) A 的正确版本。
    func testRealWorldBadSequenceIsFixed() {
        let items: [Item] = [
            .user(id: "u1", text: "第一问", images: []),
            .turnBreak(id: "tb-017a37", at: Date(), duration: 7),
            .agent(id: "a1", text: "答一"),
            .reasoning(id: "r1", text: "想一"),
            .turnBreak(id: "tb-local-245C5E", at: Date(), duration: nil),
            .user(id: "u2", text: "第二问", images: []),
            .turnBreak(id: "tb-d7c92e", at: Date(), duration: 4),
            .reasoning(id: "r2", text: "想二"),
            .agent(id: "a2", text: "答二")
        ]
        let out = kinds(Grouping.rows(items, liveTurnId: nil))
        print("### 修完 → " + out)
        XCTAssertEqual(out, "UW(TR)AUW(TR)A", "顺序还是错的：\(out)")
    }

    /// 分隔线必须归位到所属回合的用户消息**之后**（`rows()` 的约定）。
    func testBreakMovesAfterItsUserMessage() {
        let items: [Item] = [
            .user(id: "u1", text: "问", images: []),
            .agent(id: "a1", text: "答"),
            .turnBreak(id: "tb-1", at: Date(), duration: 5)
        ]
        let norm = Grouping.normalizeBreaks(items)
        let letters = norm.map { Grouping.letter($0) }.joined()
        print("### 归位 → " + letters)
        XCTAssertEqual(letters, "UTA")
    }

    /// 重复的分隔线只留一条，且留**有耗时**的那条。
    func testDuplicateBreaksKeepTheTimedOne() {
        let items: [Item] = [
            .user(id: "u1", text: "问", images: []),
            .turnBreak(id: "tb-local-x", at: Date(), duration: nil),
            .turnBreak(id: "tb-server", at: Date(), duration: 9),
            .agent(id: "a1", text: "答")
        ]
        let norm = Grouping.normalizeBreaks(items)
        let breaks = norm.compactMap { it -> Double? in
            if case .turnBreak(_, _, let d) = it { return d ?? -1 }
            return nil
        }
        print("### 去重后分隔线 = \(breaks)")
        XCTAssertEqual(breaks.count, 1, "重复的分隔线没去掉")
        XCTAssertEqual(breaks.first, 9, "留下了没耗时的那条")
    }

    /// 没有用户消息时不能乱动。
    func testBreakWithoutUserMessageStays() {
        let items: [Item] = [
            .turnBreak(id: "tb-1", at: Date(), duration: 3),
            .agent(id: "a1", text: "答")
        ]
        let letters = Grouping.normalizeBreaks(items).map { Grouping.letter($0) }.joined()
        XCTAssertEqual(letters, "TA")
    }

    /// 回合进行中：思考在正文前，不折叠。
    func testLiveTurnKeepsOrder() {
        let items: [Item] = [
            .turnBreak(id: "tb-local-x", at: Date(), duration: nil),
            .user(id: "u1", text: "问", images: []),
            .turnBreak(id: "tb-1", at: Date(), duration: nil),
            .reasoning(id: "r1", text: "想"),
            .agent(id: "a1", text: "答")
        ]
        let out = kinds(Grouping.rows(items, liveTurnId: "1"))
        print("### 进行中 → " + out)
        // 分隔线归位在用户消息之后，所以是 UTRA（思考在正文前）。
        XCTAssertEqual(out, "UTRA", "进行中顺序不对：\(out)")
    }
}

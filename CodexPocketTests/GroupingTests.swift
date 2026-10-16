import XCTest
@testable import CodexPocket

/// 回合折叠。
///
/// 用户截图里的问题：一次任务下来 `已思考`、`/bin/bash -lc ...` 各占一行，
/// 十几行中间过程把真正的回复挤出屏幕。
///
/// 规则（照 Happy 的 `useGroupedMessages`）：
///   进行中的回合**不折叠**（正在发生的事要看得见）
///   结束的回合把中间过程收成一组
final class GroupingTests: XCTestCase {

    private func work() -> [Item] {
        [.turnBreak(id: "tb-T1", at: Date(), duration: 12),
         .reasoning(id: "r1", text: "想想"),
         .command(id: "c1", command: "ls", output: "a"),
         .command(id: "c2", command: "pwd", output: "/tmp"),
         .fileChange(id: "f1", changes: [FileChange(path: "/a", kind: "update",
                                                     diff: "", added: 1, removed: 0)]),
         .agent(id: "a1", text: "做完了")]
    }

    /// 回合结束后：中间过程折成**一条**，回复还在外面。
    func testCompletedTurnFolds() {
        let rows = Grouping.rows(work(), liveTurnId: nil)
        let works = rows.filter { if case .work = $0 { return true }; return false }
        XCTAssertEqual(works.count, 1, "中间过程没折成一条")
        XCTAssertEqual(rows.count, 2, "应该只剩「一组过程 + 一条回复」")
        // 回复必须在外面。
        let agents = rows.filter {
            if case .one(let i) = $0, i.isAgent { return true }
            return false
        }
        XCTAssertEqual(agents.count, 1)
    }

    /// 进行中的回合**不折叠** —— 每一秒都在变，收起来就看不到进展。
    func testLiveTurnStaysFlat() {
        let rows = Grouping.rows(work(), liveTurnId: "T1")
        let works = rows.filter { if case .work = $0 { return true }; return false }
        XCTAssertTrue(works.isEmpty, "进行中的回合被折起来了，看不到进展")
    }

    /// 折叠不能吞内容：组里的成员数 = 分隔线 + 全部工作条目。
    func testFoldKeepsEveryMember() {
        let rows = Grouping.rows(work(), liveTurnId: nil)
        guard case .work(_, let members, _, _)? = rows.first(where: {
            if case .work = $0 { return true }; return false
        }) else { return XCTFail("没有折叠组") }
        // work() 里是 4 条工作条目（思考 1 + 命令 2 + 改文件 1）+ 1 条分隔线
        XCTAssertEqual(members.count, 5, "折叠时丢了内容")
        XCTAssertTrue(members.contains { $0.id == "r1" }, "思考丢了")
        XCTAssertTrue(members.contains { $0.id == "c1" }, "命令丢了")
        XCTAssertTrue(members.contains { $0.id == "f1" }, "改动丢了")
    }

    /// 摘要要能看出干了什么。
    func testSummaryMentionsWork() {
        let rows = Grouping.rows(work(), liveTurnId: nil)
        guard let w = rows.first(where: { if case .work = $0 { return true }; return false })
        else { return XCTFail("没有折叠组") }
        let s = w.summary
        XCTAssertTrue(s.contains("命令 2"), "摘要里没提命令数：\(s)")
        XCTAssertTrue(s.contains("改文件 1"), "摘要里没提改动数：\(s)")
        XCTAssertTrue(s.contains("思考"), "摘要里没提思考：\(s)")
    }

    /// 用户消息永远单独一行，不能被折进组里。
    func testUserMessageNeverFolded() {
        var items = work()
        items.insert(.user(id: "u1", text: "你好", images: []), at: 1)
        let rows = Grouping.rows(items, liveTurnId: nil)
        let userRows = rows.filter {
            if case .one(let i) = $0, case .user = i { return true }
            return false
        }
        XCTAssertEqual(userRows.count, 1, "用户消息被折进中间过程了")
    }

    /// 没有分隔线兜着的孤儿工作条目不能丢。
    func testOrphanWorkIsNotDropped() {
        let rows = Grouping.rows([.reasoning(id: "r9", text: "x")], liveTurnId: nil)
        XCTAssertEqual(rows.count, 1)
        guard case .one = rows[0] else { return XCTFail("孤儿条目被吞了") }
    }

    func testWhitespaceOnlyAgentDoesNotCreateBlankRow() {
        let rows = Grouping.rows([
            .agent(id: "blank", text: " \n\u{2028}\t"),
            .agent(id: "real", text: "  有正文  ")
        ], liveTurnId: nil)
        XCTAssertEqual(rows.count, 1)
        guard case .one(.agent(let id, let text)) = rows[0] else {
            return XCTFail("有效正文被误删")
        }
        XCTAssertEqual(id, "real")
        XCTAssertEqual(text, "  有正文  ")
    }
}

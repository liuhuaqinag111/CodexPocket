import XCTest
@testable import CodexPocket

/// 服务端广播的会话事件要落到本地状态上。
///
/// 以前 `thread/deleted` / `thread/archived` / `thread/unarchived`
/// 客户端**一个都没处理** —— 电脑端删掉的会话在手机列表里永远留着，
/// 点进去报 "thread not loaded"；归档状态两边永远不一致。
///
/// 这些测试**直接调状态层**，不走 UI。UI 版的反向验证会被"重连时
/// 顺手 load() 一次"掩盖（实测：去掉修复后 UI 测试照样过），
/// 所以回归覆盖放在这里。
final class RemoteEventTests: XCTestCase {
    @MainActor
    func testAgentMessageTextKeepsSupplementaryQuestionsInHistoryAndEvents() {
        let raw: JSONDict = ["id": "a", "type": "agentMessage", "text": "Choose a path",
            "questions": [["id": "q", "header": "Path", "question": "Which path?",
                           "options": [["label": "first", "description": "one"]]]]]
        let history = Protocol_.items(fromTurn: ["id": "t", "items": [raw]])
        XCTAssertTrue(history.contains(.agent(id: "a", text: "Choose a path")))
        XCTAssertTrue(history.contains { if case .question(let id, _) = $0 { return id == "a-questions" }; return false })
        let store = AppCoordinator(); store.list.currentID = "t"
        for _ in 0..<2 { store.chat.apply("item/completed", ["threadId": "t", "item": raw]) }
        XCTAssertEqual(store.chat.items.count, 2)
    }
    func testUnifiedDiffHandlesAddDeleteAndHunkTextLikeHeaders() {
        let diff = "diff --git a/new.txt b/new.txt\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+++ not-a-path\n"
            + "diff --git a/gone.txt b/gone.txt\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n"
        let changes = Protocol_.fileChangesFromUnifiedDiff(diff)
        XCTAssertEqual(changes.map(\.path), ["new.txt", "gone.txt"])
        XCTAssertEqual(changes.map(\.kind), ["add", "delete"])
        XCTAssertEqual(changes.map(\.added), [1, 0])
        XCTAssertEqual(changes.map(\.removed), [0, 1])
    }
    @MainActor
    func testNativePlanUpdatesKeepDifferentTurnsSeparate() {
        let store = AppCoordinator(); store.list.currentID = "t"
        for turn in ["one", "two"] {
            store.chat.apply("turn/plan/updated", ["threadId": "t", "turnId": turn,
                "plan": [["step": turn, "status": "pending"]]])
        }
        store.chat.apply("turn/plan/updated", ["threadId": "t", "turnId": "two",
            "plan": [["step": "finished", "status": "completed"]]])
        XCTAssertEqual(store.chat.items, [.plan(id: "plan-one", steps: [.init(text: "one", status: "pending")]),
            .plan(id: "plan-two", steps: [.init(text: "finished", status: "completed")])])
    }

    @MainActor
    func testNativeAggregatedDiffReplacesCurrentTurnOnly() {
        let store = AppCoordinator(); store.list.currentID = "t"
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new"
        for turn in ["one", "two"] {
            store.chat.apply("turn/diff/updated", ["threadId": "t", "turnId": turn, "diff": diff])
        }
        store.chat.apply("turn/diff/updated", ["threadId": "t", "turnId": "two", "diff": ""])
        XCTAssertEqual(store.chat.items.map(\.id), ["fc-one", "fc-two"])
        guard case .fileChange(_, let first) = store.chat.items[0],
              case .fileChange(_, let second) = store.chat.items[1] else { return XCTFail("diff events missing") }
        XCTAssertEqual(first.first?.path, "a.txt"); XCTAssertEqual(first.first?.added, 1)
        XCTAssertEqual(first.first?.removed, 1); XCTAssertTrue(second.isEmpty)
    }

    @MainActor
    func testDeltasKeepArrivalOrderWithoutStartedEvents() {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-stream"
        for (method, id) in [("item/agentMessage/delta", "a"),
                             ("item/reasoning/textDelta", "r"),
                             ("item/commandExecution/outputDelta", "c")] {
            store.chat.apply(method, ["threadId": "synthetic-stream", "itemId": id, "delta": id])
        }
        store.chat.flush()
        XCTAssertEqual(store.chat.items.map(\.id), ["a", "r", "c"])
        XCTAssertEqual(store.chat.items, [.agent(id: "a", text: "a"),
                                          .reasoning(id: "r", text: "r"),
                                          .command(id: "c", command: "", output: "c")])
    }

    @MainActor
    func testWhitespaceDeltaPlaceholderBecomesVisibleWhenTextArrives() {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-stream"
        store.chat.apply("item/agentMessage/delta", ["threadId": "synthetic-stream",
                                                       "itemId": "a", "delta": " "])
        store.chat.flush()
        XCTAssertEqual(store.chat.items, [.agent(id: "a", text: " ")])
        store.chat.apply("item/agentMessage/delta", ["threadId": "synthetic-stream",
                                                       "itemId": "a", "delta": "answer"])
        store.chat.flush()
        XCTAssertEqual(store.chat.items, [.agent(id: "a", text: " answer")])
        let rows = Grouping.rows(store.chat.items, liveTurnId: nil)
        guard case .one(.agent(_, let text)) = rows.first else {
            return XCTFail("真实正文到达后占位行没有恢复")
        }
        XCTAssertEqual(text, " answer")
    }

    @MainActor
    func testUnscopedDeltaCannotEnterCurrentThread() {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-A"
        store.chat.apply("item/agentMessage/delta", ["itemId": "foreign", "delta": "wrong"])
        store.chat.flush()
        XCTAssertTrue(store.chat.items.isEmpty)
    }

    @MainActor
    func testCompletedItemArrivingWithoutStartIsKeptOnce() {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-A"
        let event: JSONDict = ["threadId": "synthetic-A", "item": [
            "id": "a", "type": "agentMessage", "text": "answer"]]
        store.chat.apply("item/completed", event)
        store.chat.apply("item/completed", event)
        XCTAssertEqual(store.chat.items, [.agent(id: "a", text: "answer")])
    }

    @MainActor
    func testOldCompletionDoesNotStopNewTurn() {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-A"
        store.chat.busy = true
        store.chat.localTurn = true
        store.chat.serverTurnId = "new"
        store.chat.apply("turn/completed", ["threadId": "synthetic-A",
                                           "turn": ["id": "old"]])
        XCTAssertTrue(store.chat.busy)
        XCTAssertEqual(store.chat.serverTurnId, "new")
    }

    private func mk(_ id: String, title: String = "t", archived: Bool = false) -> CodexPocket.Thread {
        Thread(json: ["id": id, "name": title, "cwd": "/tmp", "archived": archived,
                      "updatedAt": 1_700_000_000])!
    }

    @MainActor
    func testDroppedRemovesFromBothLists() {
        let store = AppCoordinator()
        store.list.__testSeed(threads: [mk("a"), mk("b")],
                              archived: [mk("c", archived: true)])

        store.list.dropped("a")
        store.list.dropped("c")

        XCTAssertFalse(store.list.threads.contains { $0.id == "a" }, "没从默认列表里摘掉")
        XCTAssertFalse(store.list.archived.contains { $0.id == "c" }, "没从归档列表里摘掉")
        XCTAssertTrue(store.list.threads.contains { $0.id == "b" }, "误删了别的会话")
    }

    /// 删掉的正好是当前打开的会话 → 当前会话要清空，
    /// 否则界面还停在一条已经不存在的会话上。
    @MainActor
    func testDroppedClearsCurrentThread() {
        let store = AppCoordinator()
        store.list.__testSeed(threads: [mk("a")], archived: [])
        store.list.currentID = "a"

        store.list.dropped("a")

        XCTAssertNil(store.list.currentID, "当前会话被删了却没清空")
    }

    @MainActor
    func testMarkArchivedMovesBetweenLists() {
        let store = AppCoordinator()
        store.list.__testSeed(threads: [mk("a"), mk("b")], archived: [])

        store.list.markArchived("a", true)
        XCTAssertFalse(store.list.threads.contains { $0.id == "a" }, "归档后还在默认列表")
        XCTAssertTrue(store.list.archived.contains { $0.id == "a" }, "没进归档列表")

        store.list.markArchived("a", false)
        XCTAssertTrue(store.list.threads.contains { $0.id == "a" }, "取消归档后没回到默认列表")
        XCTAssertFalse(store.list.archived.contains { $0.id == "a" }, "取消归档后还在归档列表")
    }

    /// 未知 id 不能崩、也不能动别的。
    @MainActor
    func testMarkArchivedUnknownIdIsNoop() {
        let store = AppCoordinator()
        store.list.__testSeed(threads: [mk("a")], archived: [])
        store.list.markArchived("zzz", true)
        store.list.markArchived("zzz", false)
        XCTAssertEqual(store.list.threads.count, 1)
        XCTAssertEqual(store.list.archived.count, 0)
    }
}

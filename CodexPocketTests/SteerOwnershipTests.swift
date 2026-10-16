import XCTest
@testable import CodexPocket

/// 用户报的：「一直在一个会话里插话能用，我一切出去插话就变成排队了」。
///
/// 根因两条，都在"切会话时清状态"上：
///   1. `open()` 把 `serverTurnId` 清成 nil —— `turn/steer` 的
///      `expectedTurnId` 必填，没 id 只能降级排队；
///   2. `localTurn` 一起被清成 false —— 轮询看到活动回合时把**手机自己**
///      的回合判成"电脑端占着"，`desktopLocked` 置上后永远排队。
@MainActor
final class SteerOwnershipTests: XCTestCase {
    private func store() -> (AppCoordinator, RecordingTransport) {
        let transport = RecordingTransport()
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), namespace: "steer-ownership")
        return (AppCoordinator(transport: transport, cache: cache), transport)
    }

    private func seedLive(_ chat: ConversationModel) {
        chat.list.currentID = "A"
        chat.busy = true
        chat.localTurn = true
        chat.serverTurnId = "turn-A"
        chat.lastTurnId = "turn-A"
        chat.items = [.user(id: "u", text: "task", images: []),
                      .turnBreak(id: "tb-turn-A", at: Date(timeIntervalSince1970: 123), duration: nil),
                      .reasoning(id: "r", text: "think"), .agent(id: "a", text: "answer")]
    }

    private func snapshot(answer: String, reason: String, status: String = "inProgress") -> JSONDict {
        ["data": [["id": "turn-A", "status": status, "startedAt": 123,
            "items": [["id": "u", "type": "userMessage", "content": [["type": "text", "text": "task"]]],
                      ["id": "r", "type": "reasoning", "summary": [["type": "summary_text", "text": reason]]],
                      ["id": "a", "type": "agentMessage", "text": answer],
                      ["id": "cmd", "type": "commandExecution", "command": "pwd", "aggregatedOutput": "/repo"]]]]]
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testActiveTranscriptSurvivesSwitchWithUnflushedDeltas() {
        let (store, _) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.apply("item/agentMessage/delta", ["threadId": "A", "itemId": "a", "delta": "+buffer"])
        chat.apply("item/reasoning/textDelta", ["threadId": "A", "itemId": "r", "delta": "+buffer"])
        chat.open(id: "B")
        chat.open(id: "A")
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "answer+buffer")))
        XCTAssertTrue(chat.items.contains(.reasoning(id: "r", text: "think+buffer")))
    }

    func testOffscreenCompletionRestoresFullTranscriptWithoutLeakingIntoB() async {
        let (store, transport) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.open(id: "B")
        chat.items = [.agent(id: "b", text: "B answer")]
        chat.apply("item/agentMessage/delta", ["threadId": "A", "itemId": "a", "delta": "+away"])
        chat.apply("item/reasoning/textDelta", ["threadId": "A", "itemId": "r", "delta": "+away"])
        chat.apply("turn/completed", ["threadId": "A", "turn": ["id": "turn-A"]])
        chat.flush()
        XCTAssertEqual(chat.items, [.agent(id: "b", text: "B answer")])
        transport.result = .success(snapshot(answer: "answer+away", reason: "think+away", status: "completed"))
        chat.open(id: "A")
        await waitUntil { chat.items.contains(.agent(id: "a", text: "answer+away")) && !chat.busy }
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "answer+away")))
        XCTAssertTrue(chat.items.contains(.reasoning(id: "r", text: "think+away")))
        XCTAssertFalse(chat.items.contains { $0.id == "b" })
        XCTAssertFalse(chat.busy)
        XCTAssertFalse(chat.localTurn)
    }

    func testFullCatchUpRestoresMissingItemsInReopenedLocalTurn() async {
        let (store, transport) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.open(id: "B")
        chat.open(id: "A")
        chat.items.removeAll { $0.id == "r" }
        transport.result = .success(snapshot(answer: "answer", reason: "think+away"))
        chat.catchUp()
        await waitUntil { chat.items.contains(.reasoning(id: "r", text: "think+away")) }
        XCTAssertTrue(chat.items.contains(.reasoning(id: "r", text: "think+away")))
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "answer")))
        XCTAssertEqual(chat.items.filter { $0.id == "a" }.count, 1)
        XCTAssertEqual(chat.items.filter { $0.id == "r" }.count, 1)
    }

    func testStaleFullCatchUpDoesNotShortenOrRepeatContinuousStream() async {
        let (store, transport) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.apply("item/agentMessage/delta", ["threadId": "A", "itemId": "a", "delta": "+live"])
        chat.apply("item/reasoning/textDelta", ["threadId": "A", "itemId": "r", "delta": "+live"])
        transport.result = .success(snapshot(answer: "ans", reason: "th"))
        chat.catchUp()
        chat.flush()
        await waitUntil { chat.remoteStatus.hasPrefix("补拉") }
        XCTAssertTrue(chat.remoteStatus.hasPrefix("补拉"))
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "answer+live")))
        XCTAssertTrue(chat.items.contains(.reasoning(id: "r", text: "think+live")))
        chat.apply("item/agentMessage/delta", ["threadId": "A", "itemId": "a", "delta": "+next"])
        chat.flush()
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "answer+live+next")))
        XCTAssertEqual(chat.items.filter { $0.id == "a" }.count, 1)
    }

    func testReopenedActiveTurnKeepsReasoningUncollapsed() {
        let (store, _) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.open(id: "B")
        chat.open(id: "A")
        let rows = Grouping.rows(chat.items, liveTurnId: chat.busy ? chat.lastTurnId : nil, gen: chat.gen)
        XCTAssertTrue(rows.contains { if case .one(.reasoning) = $0 { return true }; return false })
        XCTAssertFalse(rows.contains { if case .work = $0 { return true }; return false })
    }

    func testServerChangeCannotRestoreOldActiveTranscriptForSameThreadId() async {
        let (store, _) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.open(id: "B")
        store.prepareConnection(namespace: "other-host")
        chat.open(id: "A")
        XCTAssertTrue(chat.items.isEmpty)
        await waitUntil { !chat.loading && chat.netMs >= 0 }
        XCTAssertTrue(chat.items.isEmpty)
        XCTAssertNil(chat.serverTurnId)
        XCTAssertFalse(chat.localTurn)
    }

    func testFullHistoryCannotAppendUnflushedDeltaTwice() {
        let (store, _) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.apply("item/agentMessage/delta", ["threadId": "A", "itemId": "a", "delta": "+now"])
        chat.apply("item/reasoning/textDelta", ["threadId": "A", "itemId": "r", "delta": "+now"])
        chat.mergeTail(Protocol_.items(fromTurns: snapshot(answer: "answer+now", reason: "think+now")))
        chat.flush()
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "answer+now")))
        XCTAssertTrue(chat.items.contains(.reasoning(id: "r", text: "think+now")))
    }

    func testReplayedTurnStartCannotHideHistoryAfterDisconnect() async {
        let (store, transport) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.open(id: "B")
        chat.apply("turn/started", ["threadId": "A", "turn": ["id": "turn-A"]])
        chat.apply("bridge/upstream", ["connected": false])
        chat.open(id: "A")
        transport.result = .success(snapshot(answer: "answer+recovered", reason: "think+recovered"))
        chat.catchUp()
        await waitUntil { chat.items.contains(.agent(id: "a", text: "answer+recovered")) }
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "answer+recovered")))
        XCTAssertTrue(chat.items.contains(.reasoning(id: "r", text: "think+recovered")))
    }

    func testSteerSurvivesThreadSwitch() async throws {
        let (store, transport) = store()
        let chat = store.chat
        chat.list.currentID = "t1"
        chat.busy = true
        chat.localTurn = true
        chat.serverTurnId = "turn-1"

        // **真实的切换路径**：以前这里把归属清掉，插话就降级成排队。
        chat.open(id: "t2")
        chat.open(id: "t1")

        XCTAssertEqual(chat.serverTurnId, "turn-1", "切回来丢了活动回合 id")
        XCTAssertTrue(chat.localTurn, "切回来把手机自己的回合判成了电脑端的")
        XCTAssertFalse(chat.desktopLocked, "手机自己的回合被标成了电脑端占着")
        store.composer.text = "改一下方向"
        XCTAssertEqual(store.composer.action, .steer, "在跑的回合里输入内容应该是插话")
        store.composer.submit()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(transport.calls.contains { $0.0 == "turn/steer" },
                      "插话降级了，实际调用：\(transport.calls.map(\.0))")
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/add" },
                       "插话变成了排队")
        store.chat.close()
    }

    func testLongOffscreenStreamCanRecoverFromFullHistory() async {
        let (store, transport) = store(), chat = store.chat
        defer { chat.close() }
        seedLive(chat)
        chat.apply("turn/started", ["threadId": "A", "turn": ["id": "turn-A"]])
        chat.open(id: "B")
        for index in 0..<600 {
            let method = index.isMultiple(of: 2) ? "item/agentMessage/delta" : "item/reasoning/textDelta"
            chat.apply(method, ["threadId": "A", "itemId": index.isMultiple(of: 2) ? "a" : "r", "delta": "x"])
        }
        chat.open(id: "A")
        let suffix = String(repeating: "x", count: 300)
        transport.result = .success(snapshot(answer: "answer" + suffix, reason: "think" + suffix))
        chat.catchUp()
        await waitUntil { chat.items.contains { $0.id == "cmd" } }
        XCTAssertTrue(chat.items.contains(.command(id: "cmd", command: "pwd", output: "/repo")))
    }

    func testDiscontinuousHistoryCanAdvanceToAnotherTurn() async {
        for method in ["reload", "catchUp", "poll"] {
            for status in ["inProgress", "completed"] {
                let (store, wire) = store(), chat = store.chat
                seedLive(chat)
                chat.invalidateStreamContinuity()
                var data = snapshot(answer: "next answer", reason: "next thought", status: status)
                var turns = data.dicts("data")
                turns[0]["id"] = "next-turn"
                data["data"] = turns
                wire.result = .success(data)
                if method == "reload" { chat.reload() }
                else if method == "catchUp" { chat.catchUp() }
                else { chat.pollRemote("A") }
                await waitUntil { status == "completed" ? !chat.busy : chat.serverTurnId == "next-turn" }
                XCTAssertEqual(chat.serverTurnId, status == "completed" ? nil : "next-turn", method)
                XCTAssertEqual(chat.busy, status != "completed", method)
                chat.close()
            }
        }
    }

    /// 切回来但本地没有回合 id（app 重启过）→ 现问一次服务端，然后插话。
    func testSteerResolvesTurnIdInsteadOfQueueing() async throws {
        let (store, transport) = store()
        let chat = store.chat
        chat.list.currentID = "t1"
        chat.busy = true
        chat.localTurn = true
        transport.result = .success(["data": [
            ["id": "turn-live", "status": "inProgress",
             "items": [["id": "u", "type": "userMessage", "clientId": "local-old"]]]
        ]] as JSONDict)
        chat.steer("改一下方向", localID: "local-ask")
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(transport.calls.contains { $0.0 == "thread/turns/list" },
                      "没去问活动回合 id，实际：\(transport.calls.map(\.0))")
        let steer = transport.calls.first { $0.0 == "turn/steer" }
        XCTAssertEqual(steer?.1.str("expectedTurnId"), "turn-live",
                       "插话没带上服务端给的活动回合 id")
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/add" },
                       "插话被降级成排队")
        store.chat.close()
    }

    /// 轮询看到活动回合时按 `clientUserMessageId` 认领归属：
    /// 不能因为 `localTurn=false` 就把**手机自己**的回合判成电脑端的。
    func testPollClaimsOwnTurnByClientId() async throws {
        let (store, transport) = store()
        let chat = store.chat
        chat.list.currentID = "t1"
        chat.open(id: "t1")
        // 模拟"切回来之后"：本地不认为这是自己的回合，服务端还标着在跑。
        chat.busy = true
        chat.acceptedSubmissionIDs.insert("local-mine")
        transport.result = .success(["data": [[
            "id": "turn-mine", "status": "inProgress",
            "items": [["id": "u", "type": "userMessage", "clientId": "local-mine"]]
        ]]] as JSONDict)
        chat.pollRemote("t1")
        for _ in 0..<40 { await Task.yield() }
        XCTAssertFalse(chat.desktopLocked,
                       "手机自己发起的回合被轮询判成了电脑端占着")
        XCTAssertTrue(chat.ownedTurnThreads.contains("t1"), "归属没认领回来")
        XCTAssertEqual(chat.serverTurnId, "turn-mine", "活动回合 id 没记下来")
        store.chat.close()
    }

    /// 真不是我们的回合（没有 clientId 认领）→ 仍然要标成电脑端占着。
    func testPollKeepsForeignTurnLocked() async throws {
        let (store, transport) = store()
        let chat = store.chat
        chat.list.currentID = "t1"
        chat.open(id: "t1")
        chat.busy = true
        transport.result = .success(["data": [[
            "id": "turn-desktop", "status": "inProgress",
            "items": [["id": "u", "type": "userMessage", "clientId": "local-desktop"]]
        ]]] as JSONDict)
        chat.pollRemote("t1")
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(chat.desktopLocked, "电脑端发起的回合没被标成占着")
        store.chat.close()
    }

    /// 电脑端真占着的会话：切走再回来还得记得被占着，不能又去撞写者锁。
    func testDesktopLockSurvivesThreadSwitch() async throws {
        let (store, _) = store()
        let chat = store.chat
        chat.list.currentID = "t1"
        chat.desktopLocked = true
        chat.open(id: "t2")
        chat.open(id: "t1")
        XCTAssertTrue(chat.desktopLocked, "切回来忘了电脑端占着这个会话")
        store.chat.close()
    }

    /// 电脑端发起的回合不能被认领成本机的。
    func testForeignTurnIsNotClaimedAsOwned() async throws {
        let (store, _) = store()
        let chat = store.chat
        chat.list.currentID = "t1"
        XCTAssertFalse(chat.ownsTurn(clientID: "local-someone-else"))
        XCTAssertFalse(chat.ownsTurn(clientID: nil))
        store.chat.close()
    }
}

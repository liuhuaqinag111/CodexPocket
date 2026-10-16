import XCTest
@testable import CodexPocket

/// 用户报的两件事的回归锁：
///   1. 「每次点发送之后有一筐英文弹出来」
///   2. 「一下发送两条一样的消息」
final class SendFixTests: XCTestCase {
    @MainActor
    func testQuestionOptionSteersRunningDesktopTurn() {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        defer { store.chat.close() }
        store.list.currentID = "t1"
        store.chat.busy = true
        store.chat.desktopLocked = true
        store.chat.serverTurnId = "active-turn"
        let option = Question.Option(id: "a", label: "先修插话", detail: "")
        let question = Question(id: "q", header: "选择", text: "先修哪个？", options: [option])
        store.chat.answer(question, option: option)
        XCTAssertEqual(transport.calls.map(\.0), ["turn/steer"])
        XCTAssertEqual(transport.calls.first?.1.str("expectedTurnId"), "active-turn")
        XCTAssertEqual(transport.calls.first?.1.dicts("input").first?.str("text"), "先修插话")
    }

    @MainActor
    func testQuestionOptionResolvesTurnBeforeSteeringAfterNavigation() async throws {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        defer { store.chat.close() }
        store.chat.resetSession()
        store.list.currentID = "t1"
        store.chat.busy = true
        let option = Question.Option(id: "a", label: "方案 A", detail: "")
        let question = Question(id: "q", header: "", text: "选择", options: [option])
        store.chat.answer(question, option: option)
        XCTAssertEqual(transport.calls.map(\.0), ["thread/turns/list"])
        let reply = try XCTUnwrap(transport.pending)
        reply(.success(["data": [["id": "live", "status": "inProgress"]]] as JSONDict))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(transport.calls.map(\.0), ["thread/turns/list", "turn/steer"])
        XCTAssertEqual(transport.calls.last?.1.str("expectedTurnId"), "live")
    }

    @MainActor
    func testQuestionOptionStartsTurnWhenConversationIsIdle() async {
        let transport = RecordingTransport()
        let store = AppCoordinator(transport: transport)
        defer { store.chat.close() }
        store.list.currentID = "t1"
        let option = Question.Option(id: "a", label: "继续", detail: "")
        let question = Question(id: "q", header: "", text: "选择", options: [option])
        store.chat.answer(question, option: option)
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(transport.calls.contains { $0.0 == "turn/start" })
        XCTAssertFalse(transport.calls.contains { $0.0 == "turn/steer" || $0.0 == "thread/queue/add" })
    }

    @MainActor
    func testQuestionOptionDoesNotSubmitDuringConfigurationPreparation() {
        let transport = RecordingTransport()
        let store = AppCoordinator(transport: transport)
        defer { store.chat.close() }
        store.list.currentID = "t1"
        store.chat.busy = true
        store.chat.configurationPreparing = true
        let option = Question.Option(id: "a", label: "继续", detail: "")
        let question = Question(id: "q", header: "", text: "选择", options: [option])
        store.chat.answer(question, option: option)
        XCTAssertTrue(transport.calls.isEmpty)
    }

    @MainActor
    func testStopBeforeStartAckInterruptsOriginalTurnAfterNavigation() async throws {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.startTurn(threadId: "t1", text: "取消", images: [],
                             localId: "start-pending", configurationReady: true)
        let resume = try XCTUnwrap(transport.pending)
        resume(.success([:] as JSONDict))
        for _ in 0..<20 { await Task.yield() }
        let started = try XCTUnwrap(transport.pending)
        store.chat.interrupt()
        store.chat.resetSession()
        store.list.currentID = "t2"
        started(.success(["turn": ["id": "original-turn", "status": "inProgress"]] as JSONDict))
        for _ in 0..<30 { await Task.yield() }
        let stop = transport.calls.filter { $0.0 == "turn/interrupt" }
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(stop.first?.1.str("threadId"), "t1")
        XCTAssertEqual(stop.first?.1.str("turnId"), "original-turn")
        store.chat.close()
    }

    @MainActor
    func testStopWhileResumePendingSurvivesNavigation() async throws {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.startTurn(threadId: "t1", text: "取消", images: [],
                             localId: "resume-pending", configurationReady: true)
        let reply = try XCTUnwrap(transport.pending)
        store.chat.interrupt()
        store.chat.resetSession()
        store.list.currentID = "t2"
        reply(.success([:] as JSONDict))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(transport.calls.map(\.0), ["thread/resume"])
        XCTAssertFalse(store.chat.ownedTurnThreads.contains("t1"))
        store.chat.close()
    }

    @MainActor
    func testSteerLookupCannotSendOldMessageToNewServer() async throws {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), namespace: "old-host")
        let store = AppCoordinator(transport: transport, cache: cache)
        store.list.currentID = "t1"
        store.chat.steer("旧服务器的消息", localID: "old-message")
        let reply = try XCTUnwrap(transport.pending)
        cache.setNamespace("new-host")
        reply(.success(["data": []] as JSONDict))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(transport.calls.map(\.0), ["thread/turns/list"])
        store.chat.close()
    }

    @MainActor
    func testQueueUnknownResultAfterNavigationStillReconciles() async throws {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.busy = true
        store.composer.sendMode = .queue
        store.composer.text = "跨会话排队"
        store.composer.submit()
        let localID = try XCTUnwrap(store.composer.outbox.first?.localID)
        let reply = try XCTUnwrap(transport.pending)

        store.chat.resetSession()
        store.list.currentID = "t2"
        reply(.failure(WebSocketTransport.RPCError(message: "连接中断", code: -32091)))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(transport.calls.contains { $0.0 == "bridge/submission/status"
            && $0.1.str("threadId") == "t1" })
        XCTAssertTrue(store.chat.uncertainSubmissionIDs.contains(localID))
        XCTAssertEqual(store.composer.outbox.first?.state, .awaitingAcknowledgement)
        store.composer.outbox = []
        store.chat.close()
    }

    @MainActor
    func testSuccessfulInterruptCleansTurnWhenNavigationChanged() async throws {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.busy = true
        store.chat.localTurn = true
        store.chat.serverTurnId = "turn-1"
        store.chat.interrupt()
        let reply = try XCTUnwrap(transport.pending)

        // Simulate switching chats before the interrupt response arrives.
        store.chat.resetSession()
        store.list.currentID = "t2"
        reply(.success([:] as JSONDict))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(store.chat.activeTurnIds["t1"],
                     "成功停止后的旧回合不能在切回来时再次显示为运行中")
        store.list.currentID = "t1"
        XCTAssertFalse(store.chat.localTurn)
        XCTAssertFalse(store.chat.busy)
        store.chat.close()
    }

    @MainActor
    func testStopDuringPreparationCancelsOnlyThatSubmissionAfterNavigation() async {
        let transport = RecordingTransport()
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.items = [.user(id: "local-prep", text: "不要发", images: [])]
        store.chat.sendingID = "local-prep"
        store.chat.configurationPreparing = true
        store.chat.interrupt()

        // The delayed preparation callback resumes after navigation.
        store.chat.openSeq += 1
        store.list.currentID = "t2"
        store.chat.startTurn(threadId: "t1", text: "不要发", images: [],
                              localId: "local-prep", configurationReady: true)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/resume" || $0.0 == "turn/start" },
                       "切会话后已停止的旧提交不能继续发出")
        XCTAssertTrue(store.chat.failed.contains("local-prep"))
        store.chat.close()
    }

    @MainActor
    func testStillQueuedMessageIsNotMarkedFailedOrDeliveredByOldText() async {
        let transport = QueueAuditTransport()
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.items = [.user(id: "old-user", text: "继续", images: []),
                            .user(id: "local-next", text: "继续", images: [])]
        store.chat.markQueued("local-next")
        store.chat.reconcileQueued(threadId: "t1", text: "继续", localId: "local-next",
                                   session: store.chat.openSeq, tries: 6)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(store.chat.items.contains { $0.id == "local-next" })
        XCTAssertTrue(store.chat.sendStates["local-next"]?.isQueued == true)
        XCTAssertFalse(store.chat.failed.contains("local-next"))
        store.chat.close()
    }

    @MainActor
    func testStaleBusyStillReconcilesQueueAfterBoundedWait() async {
        let transport = QueueAuditTransport()
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.busy = true
        store.chat.items = [.user(id: "local-next", text: "继续", images: [])]
        store.chat.markQueued("local-next")
        store.chat.reconcileQueued(threadId: "t1", text: "继续", localId: "local-next",
                                   session: store.chat.openSeq, tries: 6)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(transport.calls.contains("thread/queue/list"),
                      "busy 卡住时也要查询队列，不能永久停在排队状态")
        store.chat.close()
    }

    @MainActor
    func testIdleWriterConflictDoesNotQueueOrPromiseExecution() async {
        let transport = RecordingTransport()
        transport.result = .failure(RepositoryError(message: "thread t1 already has an active writer"))
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        let chat = store.chat
        chat.items = [.user(id: "local-lock", text: "你好", images: [])]
        chat.sendingID = "local-lock"
        chat.busy = true
        chat.localTurn = true
        chat.sendTurn(threadId: "t1", text: "你好", images: [],
                      localId: "local-lock", params: ["threadId": "t1"], attempt: 0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/add" })
        XCTAssertEqual(chat.sendStates["local-lock"], .failed("会话仍被电脑端占用，释放后重试"))
        XCTAssertFalse(chat.busy)
        XCTAssertTrue(chat.desktopLocked)
        chat.close()
    }

    @MainActor
    func testPreviouslyLockedConversationDoesNotQueueOnRetryFailure() async {
        let transport = RecordingTransport()
        transport.result = .failure(RepositoryError(message: "thread t1 already has an active writer"))
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.desktopLocked = true
        store.chat.items = [.user(id: "local-retry", text: "你好", images: [])]
        let settled = expectation(description: "writer conflict settled after bounded retries")
        store.chat.onSubmissionResolved = { id, accepted in
            XCTAssertEqual(id, "local-retry")
            XCTAssertFalse(accepted)
            settled.fulfill()
        }
        store.chat.startTurn(threadId: "t1", text: "你好", images: [], localId: "local-retry")
        await fulfillment(of: [settled], timeout: 5)
        let state = store.chat.sendStates["local-retry"]
        XCTAssertEqual(state, .failed("会话仍被电脑端占用，释放后重试"))
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/add" })
        XCTAssertEqual(transport.calls.filter { $0.0 == "thread/resume" }.count, 3)
        store.chat.close()
    }

    @MainActor
    func testRunningTurnStillAllowsQueue() async {
        let transport = RecordingTransport()
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.busy = true
        store.chat.localTurn = true
        store.chat.serverTurnId = "turn-running"
        store.chat.send("下一句")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(transport.calls.contains { $0.0 == "thread/queue/add" })
        XCTAssertFalse(transport.calls.contains { $0.0 == "turn/start" })
        XCTAssertEqual(store.chat.sendStates.values.first?.isQueued, true)
        store.chat.close()
    }

    /// 服务端每次 `thread/start` / `resume` / `turn/start` 都会推一条
    /// `configWarning`（一整段英文）。它**不能**弹成用户提示。
    @MainActor
    func testConfigWarningDoesNotBanner() {
        let store = AppCoordinator()
        let chat = store.chat
        // `apply` 只处理**当前会话**的事件，没有 currentID 会被整个丢掉。
        store.list.currentID = "t1"
        chat.banner = nil
        chat.apply("configWarning", [
            "threadId": "t1",
            "summary": "Codex is ignoring 2 unrecognized configuration settings. "
                + "Check for typos or deprecated settings.\n  user (config.toml): "
                + "`disable_response_storage` is ignored.",
        ])
        XCTAssertNil(chat.banner, "服务端的配置告警被弹成了用户提示")

        chat.apply("warning", ["threadId": "t1", "message": "same english text"])
        XCTAssertNil(chat.banner, "warning 也不该弹")

        // 真正的用户提示还是要弹的（走 `turn/completed` 带 error 那条路）。
        chat.apply("turn/completed", ["threadId": "t1", "turn": ["id": "t1",
                                               "error": ["message": "模型不可用"]]])
        XCTAssertEqual(chat.banner, "模型不可用", "回合失败没提示 —— 用户会觉得问了没反应")
    }

    /// 排队里只留一条待执行：多条排队在服务端会被**一起**执行，
    /// 界面上就成了「一次发送变成好几条一样的消息」。
    @MainActor
    func testQueuePreservesEarlierPendingMessages() {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        let chat = store.chat
        chat.queued = [ConversationModel.Queued(id: "q1", text: "旧的一条")]
        chat.enqueueRemote(threadId: "t1", text: "新的一条", images: [], localId: "local-1")
        XCTAssertEqual(chat.queued.map(\.id), ["q1"])
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/delete" })
    }

    @MainActor
    func testQueueCancelFailureKeepsMessageVisible() async {
        let transport = RecordingTransport()
        transport.result = .failure(RepositoryError(message: "offline"))
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        let q = ConversationModel.Queued(id: "q1", text: "keep")
        store.chat.queued = [q]
        store.chat.cancelQueued(q)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(store.chat.queued.map(\.id), ["q1"])
        XCTAssertNotNil(store.chat.banner)
    }

    /// 排队之后 8 秒没人执行 → 必须标红，不能一直假装"已送达"。
    @MainActor
    func testQueuedMessageThatNeverRunsIsMarkedFailed() {
        let store = AppCoordinator()
        let chat = store.chat
        chat.items = [.user(id: "local-q", text: "排队的那条", images: [])]
        chat.markQueued("local-q")
        XCTAssertFalse(chat.failed.contains("local-q"))
        XCTAssertNotNil(chat.sendStates["local-q"], "排队要有自己的状态行")
    }
}

/// 「一下发两个」的根因回归锁。
///
/// 链路：回合进行中插话 → `turn/steer` **少了必填的 `expectedTurnId`** →
/// 服务端回 "missing field `expectedTurnId`" → 降级成 `turn/start` 新开一个回合 →
/// 服务端把用户消息回显回来 → `item/completed` 当成新条目 append →
/// 界面上**两条一模一样的消息**（服务端那边只有一条）。
final class DuplicateBubbleTests: XCTestCase {

    /// 插话必须带 `expectedTurnId`（服务端必填）和 `clientUserMessageId`。
    ///
    /// 少了 `expectedTurnId` 服务端直接回
    /// "Invalid request: missing field `expectedTurnId`"（实测），
    /// 于是每次都降级成新开一个回合 —— 那正是重复气泡的来源。
    @MainActor
    func testSteerRequestCarriesRequiredFields() {
        let (method, params) = ConversationRepository.request(.steer([
            "threadId": "t1", "expectedTurnId": "turn-9",
            "clientUserMessageId": "local-1", "input": [],
        ]))
        XCTAssertEqual(method, "turn/steer")
        XCTAssertEqual(params["expectedTurnId"] as? String, "turn-9",
                       "少了 expectedTurnId，服务端会拒掉每一次插话")
        XCTAssertEqual(params["clientUserMessageId"] as? String, "local-1",
                       "少了它，回显认领不回本地那条气泡")
    }

    /// `item/started` / `item/completed` 里回显的用户消息，必须**认领**本地气泡，
    /// 而不是再插一条。
    @MainActor
    func testServerEchoAdoptsLocalBubble() {
        let store = AppCoordinator()
        store.list.currentID = "t1"
        let chat = store.chat
        chat.items = [.user(id: "local-A", text: "说人话 这有什么用", images: [])]
        chat.markSending("local-A")

        // 服务端回显：id 是服务端的，clientId 是我们带上去的本地 id。
        chat.apply("item/completed", ["threadId": "t1", "item": [
            "type": "userMessage", "id": "srv-A", "clientId": "local-A",
            "content": [["type": "text", "text": "说人话 这有什么用\n"]],
        ]])
        XCTAssertEqual(chat.items.count, 1, "回显又插了一条，界面上会有两条一样的")
        XCTAssertEqual(chat.items.first?.id, "local-A", "服务端回显必须保留客户端提交身份")
        XCTAssertNil(chat.sendStates["local-A"], "认领之后不该还挂着发送中")
    }

    /// 没有 clientId 的相同文本不能证明是本次提交，必须保留两条独立消息。
    @MainActor
    func testEchoWithoutClientIdDoesNotAcknowledgeSameText() {
        let store = AppCoordinator()
        store.list.currentID = "t1"
        let chat = store.chat
        chat.items = [.user(id: "local-B", text: "删啊", images: [])]
        chat.markSending("local-B")
        chat.apply("item/completed", ["threadId": "t1", "item": [
            "type": "userMessage", "id": "srv-B", "clientId": NSNull(),
            "content": [["type": "text", "text": "删啊\n"]],
        ]])
        XCTAssertEqual(Set(chat.items.map(\.id)), Set(["local-B", "srv-B"]))
        XCTAssertNotNil(chat.sendStates["local-B"], "无身份回显不能完成本次提交")
    }

    /// 别人的消息（对不上任何本地气泡）该照常插进来，不能被吞掉。
    @MainActor
    func testUnrelatedUserMessageStillAppends() {
        let store = AppCoordinator()
        store.list.currentID = "t1"
        let chat = store.chat
        chat.items = [.user(id: "local-C", text: "我的话", images: [])]
        chat.apply("item/completed", ["threadId": "t1", "item": [
            "type": "userMessage", "id": "srv-C", "clientId": "someone-else",
            "content": [["type": "text", "text": "电脑端发的话"]],
        ]])
        XCTAssertEqual(chat.items.count, 2, "别人的消息被吞了")
    }
}

/// 发送动作的分派：**回合在跑时绝不能退回"普通发送"**。
///
/// `turn/start` 会另起一个回合，服务端把这条用户消息回显回来 ——
/// 界面上就是两条一样的（用户报的「一下发两个」）。
final class SendActionTests: XCTestCase {

    /// 回合在跑、还不知道活动回合 id 的那一小段窗口：走插话
    /// （`steer()` 先问一次 `thread/turns/list`），**不能走普通发送**。
    @MainActor
    func testRunningTurnWithUnknownIdNeverSends() {
        let store = AppCoordinator()
        store.list.currentID = "t1"
        let c = store.composer
        store.chat.busy = true
        store.chat.lastTurnId = "turn-x"
        store.chat.serverTurnId = nil
        store.chat.localTurn = true
        c.text = "插一句"
        XCTAssertNotEqual(c.action, .send,
                          "回合在跑却走普通发送 —— 会另起一个回合、多出一条一样的消息")
        XCTAssertEqual(c.action, .steer,
                       "没 id 也该插话（先问服务端），不该直接排队")
    }

    /// id 到手之后走插话（`turn/steer`，不另起回合）。
    @MainActor
    func testRunningTurnWithKnownIdSteers() {
        let store = AppCoordinator()
        store.list.currentID = "t1"
        let c = store.composer
        store.chat.busy = true
        store.chat.serverTurnId = "turn-9"
        store.chat.localTurn = true
        c.text = "插一句"
        XCTAssertEqual(c.action, .steer)
    }

    @MainActor
    func testIdleStillSends() {
        let store = AppCoordinator()
        store.list.currentID = "t1"
        let c = store.composer
        store.chat.busy = false
        c.text = "新的一句"
        XCTAssertEqual(c.action, .send)
    }
}

private final class QueueAuditTransport: RPCTransport {
    var calls: [String] = []
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        calls.append(method)
        if method == "thread/queue/list" {
            done?(.success(["data": [["id": "queue-next", "clientUserMessageId": "local-next",
              "input": [["type": "text", "text": "继续"]]]]] as JSONDict))
        } else if method == "thread/turns/list" {
            let old: JSONDict = ["id": "old-user", "type": "userMessage", "clientId": "old-client",
                                "content": [["type": "text", "text": "继续"]]]
            done?(.success(["data": [["id": "old-turn", "items": [old]]]] as JSONDict))
        } else { done?(.success([:] as JSONDict)) }
        return 1
    }
}

/// U+2028 / U+2029 必须挡在发送之前。
///
/// 实测（2026-10-15）：rollout 正文里有一个 U+2028，app-server 的
/// `thread/read` / `thread/turns/list` / `thread/resume` 就**永远不返回**
/// —— 裸进程实测：只有 meta + 一条 UserMessage 的 rollout，
/// 正文 `a\u{2028}b` 卡死 15 秒＋，`a\nb` 1ms 返回。
/// 手机端表现是「这个会话根本打不开」，而且只有那一个会话坏。
final class LineSeparatorTests: XCTestCase {
    func testCleansLineAndParagraphSeparator() {
        let dirty = "第一行\u{2028}第二行\u{2029}第三行"
        let clean = ConversationModel.cleanText(dirty)
        XCTAssertFalse(clean.unicodeScalars.contains { $0.value == 0x2028 || $0.value == 0x2029 },
                       "U+2028/U+2029 没清掉：\(clean.unicodeScalars.map(\.value))")
        XCTAssertEqual(clean, "第一行\n第二行\n第三行", "换行语义要保持")
    }

    func testLeavesNormalTextAlone() {
        let normal = "普通文本\n第二行\r\n第三行\tabc \u{00A0} 尾巴"
        XCTAssertEqual(ConversationModel.cleanText(normal), normal, "普通文本不能被改")
    }

    /// 走真实的发送入口，量送到服务端的 params 里还有没有裸 U+2028。
    @MainActor
    func testSendPathCleansBeforeWriting() async {
        let transport = RecordingTransport()
        let store = AppCoordinator(transport: transport)
        defer { store.chat.close() }
        store.list.currentID = "t1"
        store.chat.send("带\u{2028}分隔符的一句话")
        for _ in 0..<30 { await Task.yield() }
        let starts = transport.calls.filter { $0.0 == "turn/start" }
        XCTAssertFalse(starts.isEmpty, "没发出 turn/start：\(transport.calls.map(\.0))")
        let json = String(describing: starts.map(\.1))
        XCTAssertFalse(json.contains("\u{2028}"), "turn/start 里还有裸 U+2028")
    }
}

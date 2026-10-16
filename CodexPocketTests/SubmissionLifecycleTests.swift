import XCTest
@testable import CodexPocket

private final class HeldSubmissionTransport: RPCTransport {
    var calls: [(String, JSONDict)] = []
    var pending: [String: [RepositoryResult]] = [:]
    var held: Set<String> = ["thread/resume", "turn/start"]
    var onCall: ((String) -> Void)?
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        calls.append((method, params))
        onCall?(method)
        if held.contains(method), let done { pending[method, default: []].append(done) }
        else if method == "thread/read" {
            done?(.success(["thread": ["id": params.str("threadId") ?? "a", "model": "model-a", "reasoningEffort": "high"]] as JSONDict))
        } else { done?(.success(["data": []] as JSONDict)) }
        return calls.count
    }
    func finish(_ method: String, _ result: Result<Any, Error>) {
        let callback = pending[method]?.removeFirst()
        callback?(result)
    }
}

final class SubmissionLifecycleTests: XCTestCase {
    @MainActor func testRetryStartsImmediatelyAfterQueuedTurnHasFinished() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        s.chat.items = [.user(id: "retry-idle", text: "hello", images: [])]
        s.chat.failed.insert("retry-idle")
        s.composer.outbox = [.init(threadId: "a", text: "hello", images: [],
                                   localID: "retry-idle", mode: "queue", state: .failed)]
        defer { s.composer.outbox = [] }
        s.composer.retry("retry-idle", text: "hello", images: [])
        await drain()
        wire.finish("thread/resume", .success([:] as JSONDict))
        await drain()
        XCTAssertEqual(wire.calls.filter { $0.0 == "turn/start" }.count, 1)
        XCTAssertFalse(wire.calls.contains { $0.0 == "thread/queue/add" })
    }

    @MainActor func testBubbleRetryKeepsExplicitQueueChoice() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        wire.held.insert("thread/queue/add")
        s.chat.busy = true
        s.chat.serverTurnId = "running"
        s.chat.items = [.user(id: "retry-queue", text: "later", images: [])]
        s.chat.failed.insert("retry-queue")
        s.composer.outbox = [.init(threadId: "a", text: "later", images: [],
                                   localID: "retry-queue", mode: "queue", state: .failed)]
        defer { s.composer.outbox = [] }
        s.composer.retry("retry-queue", text: "later", images: [])
        s.composer.retry("retry-queue", text: "later", images: [])
        await drain()
        XCTAssertEqual(s.composer.outbox.first?.state, .awaitingAcknowledgement)
        XCTAssertEqual(wire.calls.filter { $0.0 == "thread/queue/add" }.count, 1)
        XCTAssertFalse(wire.calls.contains { $0.0 == "turn/steer" })
    }

    @MainActor func testBusyBubbleRetrySteersSameMessageAndProtectsOutbox() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        wire.held.insert("turn/steer")
        s.chat.busy = true
        s.chat.serverTurnId = "running"
        s.chat.items = [.user(id: "retry", text: "hello", images: ["/tmp/photo.png"])]
        s.chat.failed.insert("retry")
        s.composer.outbox = [.init(threadId: "a", text: "hello", images: ["/tmp/photo.png"],
                                   localID: "retry", mode: "steer", state: .failed)]
        defer { s.composer.outbox = [] }
        s.chat.retry("retry", text: "hello", images: ["/tmp/photo.png"])
        XCTAssertEqual(s.composer.outbox.first?.state, .awaitingAcknowledgement)
        s.composer.clearFailedOutgoing()
        await drain()
        let request = wire.calls.first { $0.0 == "turn/steer" }?.1
        XCTAssertEqual(request?.str("clientUserMessageId"), "retry")
        XCTAssertEqual(request?.dicts("input").last?.str("path"), "/tmp/photo.png")
        XCTAssertFalse(wire.calls.contains { $0.0 == "thread/queue/add" })
        XCTAssertEqual(s.chat.items.filter { $0.id == "retry" }.count, 1)
    }

    @MainActor func testCompletedStartAckCannotForgetNewerActiveTurn() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        s.chat.send("old", localID: "local-old"); await drain()
        wire.finish("thread/resume", .success([:] as JSONDict)); await drain()
        s.chat.completedTurnIDs.insert("old-turn")
        s.chat.serverTurnId = "new-turn"
        s.chat.localTurn = true
        s.chat.busy = true
        s.chat.sendingID = "local-new"
        wire.finish("turn/start", .success(["turn": ["id": "old-turn"]] as JSONDict))
        await drain()
        XCTAssertEqual(s.chat.serverTurnId, "new-turn")
        XCTAssertTrue(s.chat.localTurn)
        XCTAssertTrue(s.chat.busy)
    }

    @MainActor private func fixture(_ wire: HeldSubmissionTransport) -> AppCoordinator {
        let s = AppCoordinator(transport: wire)
        s.list.inject(threads: [Thread(json: ["id": "a", "model": "model-a", "reasoningEffort": "high"])!,
                               Thread(json: ["id": "b", "model": "model-b", "reasoningEffort": "low"])!])
        s.list.currentID = "a"
        return s
    }
    private func drain() async { for _ in 0..<30 { await Task.yield() } }

    @MainActor func testSwitchDuringResumeStillStartsOriginalThreadAndResolvesACK() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        var resolved: [String] = []
        s.chat.onSubmissionResolved = { id, ok in if ok { resolved.append(id) } }
        s.chat.send("hello", localID: "local-a")
        await drain()
        s.chat.resetSession(); s.list.currentID = "b"; s.chat.items = []
        wire.finish("thread/resume", .success([:] as JSONDict))
        await drain()
        let request = wire.calls.first { $0.0 == "turn/start" }?.1
        XCTAssertEqual(request?.str("threadId"), "a")
        XCTAssertEqual(request?.str("model"), "model-a")
        XCTAssertEqual(request?.str("effort"), "high")
        wire.finish("turn/start", .success(["turn": ["id": "turn-a"]] as JSONDict))
        await drain()
        XCTAssertEqual(resolved, ["local-a"])
        XCTAssertFalse(s.chat.busy)
        XCTAssertNil(s.chat.serverTurnId)
    }

    @MainActor func testKnownFailureAfterSwitchStillSettlesPersistentOutbox() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        var failed: String?
        s.chat.onSubmissionResolved = { id, ok in if !ok { failed = id } }
        s.chat.send("hello", localID: "local-a"); await drain()
        s.chat.resetSession(); s.list.currentID = "b"; s.chat.items = []
        wire.finish("thread/resume", .failure(WebSocketTransport.RPCError(message: "worker unavailable", code: -32092)))
        await drain()
        XCTAssertEqual(failed, "local-a")
        XCTAssertTrue(s.chat.items.isEmpty)
    }

    @MainActor func testDuplicateLocalIDDoesNotSendTwice() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        s.chat.send("hello", localID: "local-a"); await drain()
        wire.finish("thread/resume", .success([:] as JSONDict)); await drain()
        s.chat.send("hello", localID: "local-a"); await drain()
        XCTAssertEqual(wire.calls.filter { $0.0 == "turn/start" }.count, 1)
        XCTAssertFalse(wire.calls.contains { $0.0 == "thread/queue/add" })
        XCTAssertEqual(s.chat.items.filter { $0.id == "local-a" }.count, 1)
    }

    @MainActor func testNoRolloutDoesNotWaitForLockRetries() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        s.chat.send("hello", localID: "local-a"); await drain()
        XCTAssertEqual(wire.calls.first { $0.0 == "thread/resume" }?.1.bool("excludeTurns"), true)
        wire.finish("thread/resume", .failure(WebSocketTransport.RPCError(message: "no rollout found")))
        await drain()
        XCTAssertEqual(wire.calls.filter { $0.0 == "turn/start" }.count, 1)
    }

    @MainActor func testCompletedBeforeStartACKDoesNotReviveTurn() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        s.chat.send("hello", localID: "local-a"); await drain()
        wire.finish("thread/resume", .success([:] as JSONDict)); await drain()
        s.chat.apply("turn/completed", ["threadId": "a", "turn": ["id": "turn-a", "status": "completed"]])
        wire.finish("turn/start", .success(["turn": ["id": "turn-a"]] as JSONDict)); await drain()
        XCTAssertFalse(s.chat.busy)
        XCTAssertNil(s.chat.serverTurnId)
        XCTAssertNil(s.chat.pendingSend)
    }

    @MainActor func testConfigurationCallbackUsesOriginalThreadAfterSwitch() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        wire.held.insert("thread/read")
        s.chat.send("hello", localID: "local-a"); await drain()
        s.chat.resetSession(); s.list.currentID = "b"; s.chat.items = []
        wire.finish("thread/read", .success(["thread": ["id": "a", "model": "model-a", "reasoningEffort": "high"]] as JSONDict))
        await drain()
        wire.finish("thread/resume", .success([:] as JSONDict)); await drain()
        let request = wire.calls.first { $0.0 == "turn/start" }?.1
        XCTAssertEqual(request?.str("threadId"), "a")
        XCTAssertEqual(request?.str("model"), "model-a")
        XCTAssertEqual(request?.str("effort"), "high")
        XCTAssertNil(request?["reasoningEffort"])
    }

    @MainActor func testKnownNotSentRoutingCodesFailButUnknownDoesNot() async {
        for code in [-32091, -32092, -32093] {
            let wire = HeldSubmissionTransport(), s = fixture(wire)
            var rejected = false
            s.chat.onSubmissionResolved = { _, ok in if !ok { rejected = true } }
            s.chat.send("hello", localID: "local-a"); await drain()
            wire.finish("thread/resume", .success([:] as JSONDict)); await drain()
            wire.finish("turn/start", .failure(WebSocketTransport.RPCError(message: "routing failed", code: code)))
            await drain()
            XCTAssertEqual(rejected, code != -32091)
        }
    }

    @MainActor func testPersistedStatusACKAfterSwitchStillResolvesOutbox() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        wire.held.insert("bridge/submission/status")
        var accepted: String?
        s.chat.onSubmissionResolved = { id, ok in if ok { accepted = id } }
        s.chat.items = [.user(id: "local-a", text: "hello", images: [])]
        s.chat.pendingSend = ("local-a", "hello")
        s.chat.confirmPending()
        s.chat.resetSession(); s.list.currentID = "b"; s.chat.items = []
        wire.finish("bridge/submission/status", .success(["state": "accepted",
            "result": ["result": ["turn": ["id": "turn-a"]]]] as JSONDict))
        await drain()
        XCTAssertEqual(accepted, "local-a")
        XCTAssertNil(s.chat.serverTurnId)
        XCTAssertTrue(s.chat.items.isEmpty)
    }

    @MainActor func testRetryMissingBubblePreservesClientID() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        s.chat.failed.insert("local-a")
        s.chat.items = []
        s.chat.retry("local-a", text: "hello")
        await drain()
        wire.finish("thread/resume", .success([:] as JSONDict)); await drain()
        XCTAssertEqual(wire.calls.first { $0.0 == "turn/start" }?.1.str("clientUserMessageId"), "local-a")
    }

    @MainActor func testStopWhileResumeWaitsCancelsBeforeStart() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        let resumed = expectation(description: "resume request is waiting")
        wire.onCall = { if $0 == "thread/resume" { resumed.fulfill() } }
        let cancelled = expectation(description: "submission cancelled")
        s.chat.onSubmissionResolved = { _, accepted in
            XCTAssertFalse(accepted)
            cancelled.fulfill()
        }
        s.chat.send("hello", localID: "local-a")
        await fulfillment(of: [resumed], timeout: 1)
        s.chat.interrupt()
        wire.finish("thread/resume", .success([:] as JSONDict))
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertFalse(wire.calls.contains { $0.0 == "turn/start" })
        XCTAssertTrue(s.chat.failed.contains("local-a"))
    }

    @MainActor func testDefiniteFailureClearsPendingGateForRetry() {
        let s = fixture(HeldSubmissionTransport())
        s.chat.items = [.user(id: "local-a", text: "hello", images: [])]
        s.chat.pendingSend = ("local-a", "hello")
        s.chat.fail("local-a", "not received")
        XCTAssertNil(s.chat.pendingSend)
    }

    @MainActor func testRecoveredACKRestoresStopForUnfinishedLocalTurn() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        wire.held.insert("bridge/submission/status")
        s.chat.items = [.user(id: "local-a", text: "hello", images: [])]
        s.chat.pendingSend = ("local-a", "hello")
        s.chat.sendingID = "local-a"
        s.chat.confirmPending()
        wire.finish("bridge/submission/status", .success(["state": "accepted",
            "result": ["result": ["turn": ["id": "turn-a", "status": "inProgress"]]]] as JSONDict))
        await drain()
        XCTAssertTrue(s.chat.canStop)
        XCTAssertEqual(s.chat.serverTurnId, "turn-a")
    }

    @MainActor func testRestartedOutboxMissingFromLedgerHistoryAndQueueCanRetry() async {
        let wire = HeldSubmissionTransport(), s = fixture(wire)
        wire.held.insert("bridge/submission/status")
        var rejected = false
        let settled = expectation(description: "restored submission confirmed missing")
        s.chat.onSubmissionResolved = { id, accepted in
            XCTAssertEqual(id, "local-restored")
            rejected = !accepted
            settled.fulfill()
        }
        s.chat.restoreSubmission(threadID: "a", localID: "local-restored", text: "hello", images: [])
        wire.finish("bridge/submission/status", .success(["state": "missing"] as JSONDict))
        await fulfillment(of: [settled], timeout: 1)
        XCTAssertTrue(rejected)
        XCTAssertTrue(s.chat.failed.contains("local-restored"))
        XCTAssertNil(s.chat.pendingSend)
        XCTAssertFalse(wire.calls.contains { $0.0 == "turn/start" })
        XCTAssertTrue(wire.calls.contains { $0.0 == "thread/turns/list" && $0.1.str("itemsView") == "full" })
        XCTAssertTrue(wire.calls.contains { $0.0 == "thread/queue/list" })
    }
}

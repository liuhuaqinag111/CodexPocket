import XCTest
@testable import CodexPocket

final class SubmissionAuditTests: XCTestCase {
    @MainActor
    func testQueueRejectionAfterSwitchStillSettlesOutbox() async {
        let wire = SubmissionAuditTransport()
        wire.queueError = WebSocketTransport.RPCError(message: "未发送", code: -32092)
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "a"
        var failed: String?
        s.chat.onSubmissionResolved = { id, ok in if !ok { failed = id } }
        s.chat.enqueueRemote(threadId: "a", text: "继续", images: [], localId: "local-q")
        s.list.currentID = "b"
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(failed, "local-q")
    }
    @MainActor
    func testRetrySteerReusesExistingBubble() {
        let s = AppCoordinator(transport: SubmissionAuditTransport())
        s.list.currentID = "t"
        s.chat.busy = true
        s.chat.serverTurnId = "running"
        s.chat.items = [.user(id: "local-retry", text: "继续", images: [])]
        s.chat.steer("继续", localID: "local-retry")
        XCTAssertEqual(s.chat.items.filter { $0.id == "local-retry" }.count, 1)
    }

    @MainActor
    func testDeliveredClientIdentityDoesNotAnchorNewTurnBeforeHistory() {
        let s = AppCoordinator(transport: SubmissionAuditTransport())
        s.chat.items = [.user(id: "local-delivered", text: "旧问题", images: []), .agent(id: "old-a", text: "旧回复")]
        s.chat.mergeTail([.user(id: "new-user", text: "新问题", images: []), .agent(id: "new-a", text: "新回复")])
        XCTAssertEqual(s.chat.items.map(\.id), ["local-delivered", "old-a", "new-user", "new-a"])
    }

    @MainActor
    func testPollingResolvesLateAcknowledgementWithoutReconnect() async {
        let wire = SubmissionAuditTransport()
        wire.status = ["state": "pending"]
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "t"
        s.chat.items = [.user(id: "local-p", text: "等待", images: [])]
        s.chat.pendingSend = ("local-p", "等待")
        s.chat.confirmPending()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(s.chat.pendingSend)
        wire.status = ["state": "accepted", "result": ["result": ["turn": ["id": "turn", "status": "completed"]]]]
        s.chat.pollRemote("t")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(s.chat.pendingSend)
        XCTAssertFalse(wire.calls.contains { $0.0 == "turn/start" })
    }
    @MainActor
    func testQueueAcceptanceResolvesPersistentSubmission() async {
        let s = AppCoordinator(transport: SubmissionAuditTransport())
        s.list.currentID = "t"
        s.chat.items = [.user(id: "local-q", text: "继续", images: [])]
        var accepted: String?
        s.chat.onSubmissionResolved = { id, ok in if ok { accepted = id } }
        s.chat.enqueueRemote(threadId: "t", text: "继续", images: [], localId: "local-q")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(accepted, "local-q")
    }

    func testHistoryKeepsSubmissionIdentity() {
        let item = Protocol_.item(from: ["type": "userMessage", "id": "server-item",
            "clientId": "local-new", "content": [["type": "text", "text": "继续"]]])
        XCTAssertEqual(item?.id, "local-new")
    }

    @MainActor
    func testTailDoesNotConsumeSameTextFromHistory() {
        let s = AppCoordinator(transport: SubmissionAuditTransport())
        s.chat.items = [.user(id: "local-new", text: "继续", images: [])]
        s.chat.markSending("local-new")
        s.chat.mergeTail([.user(id: "older", text: "继续", images: [])])
        XCTAssertEqual(s.chat.items.map(\.id), ["older", "local-new"])
        XCTAssertNotNil(s.chat.sendStates["local-new"])
    }

    @MainActor
    func testUnknownSteerNeverStartsAnotherTurn() async {
        let wire = SubmissionAuditTransport()
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "t"
        s.chat.items = [.user(id: "local-new", text: "继续", images: [])]
        s.chat.fallbackAfterSteer(threadId: "t", text: "继续", images: [], localId: "local-new")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(wire.calls.contains { $0.0 == "turn/start" })
        XCTAssertFalse(s.chat.failed.contains("local-new"))
        XCTAssertEqual(s.chat.pendingSend?.id, "local-new")
    }

    @MainActor
    func testUnknownSubmissionUsesFullHistoryAndStaysUncertain() async {
        let wire = SubmissionAuditTransport()
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "t"
        s.chat.items = [.user(id: "local-new", text: "继续", images: [])]
        s.chat.pendingSend = ("local-new", "继续")
        s.chat.confirmPending()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(wire.calls.first { $0.0 == "thread/turns/list" }?.1["itemsView"] as? String, "full")
        XCTAssertEqual(s.chat.pendingSend?.id, "local-new")
        XCTAssertFalse(s.chat.failed.contains("local-new"))
    }

    @MainActor
    func testSameWordsWithoutClientIDAreNotAcknowledgement() {
        let s = AppCoordinator(transport: SubmissionAuditTransport())
        s.chat.items = [.user(id: "local-new", text: "继续", images: [])]
        let result: JSONDict = ["data": [["items": [["type": "userMessage",
            "id": "old", "content": [["type": "text", "text": "继续"]]]]]]]
        XCTAssertFalse(s.chat.containsSubmission(result, localId: "local-new", text: "继续", images: []))
    }

    @MainActor
    func testDifferentClientIDDoesNotAdoptSameText() {
        let s = AppCoordinator(transport: SubmissionAuditTransport())
        s.chat.items = [.user(id: "local-new", text: "继续", images: [])]
        let adopted = s.chat.adoptServerUser(["clientId": "desktop"],
            .user(id: "server-old", text: "继续", images: []))
        XCTAssertFalse(adopted)
        XCTAssertEqual(s.chat.items.first?.id, "local-new")
    }
}

private final class SubmissionAuditTransport: RPCTransport {
    var queueError: Error?
    var status: JSONDict?
    var calls: [(String, JSONDict)] = []
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        calls.append((method, params))
        if method == "thread/queue/add", let error = queueError { done?(.failure(error)); return calls.count }
        done?(.success(method == "bridge/submission/status" ? (status ?? [:]) : ["data": []] as JSONDict))
        return calls.count
    }
}

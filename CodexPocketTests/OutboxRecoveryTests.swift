import XCTest
@testable import CodexPocket

@MainActor
final class OutboxRecoveryTests: XCTestCase {
    func testConfirmedFailureAutomaticallyAdvancesNextQueuedMessage() async {
        let wire = OutboxRecoveryTransport()
        wire.states["missing"] = ["state": "missing"]
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "a"
        s.composer.outbox = [
            .init(threadId: "a", text: "missing", images: [], localID: "missing", state: .awaitingAcknowledgement),
            .init(threadId: "a", text: "next", images: [], localID: "next")]
        s.composer.flushOutbox()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(s.composer.outbox.first?.state, .failed)
        XCTAssertEqual(wire.methods.filter { $0 == "turn/start" }.count, 1)
        XCTAssertEqual(s.composer.outbox.map(\.localID), ["missing"])
        s.composer.outbox = []
    }
    func testReconciliationDoesNotFailARequestStillPreparing() async throws {
        let wire = OutboxRecoveryTransport()
        wire.holdResume = true
        wire.defaultState = "missing"
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "a"
        s.composer.text = "sending"
        s.composer.submit()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertNotNil(wire.resume)
        s.composer.reconcileOutbox()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(s.composer.outbox.first?.state, .awaitingAcknowledgement)
        XCTAssertFalse(s.composer.hasFailedOutgoing)
        let release = try XCTUnwrap(wire.resume)
        release(.success([:] as JSONDict))
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(wire.methods.filter { $0 == "turn/start" }.count, 1)
        s.composer.outbox = []
    }
    func testQueueUnknownAcknowledgementCanResolveAsDefinitelyMissing() async {
        let wire = OutboxRecoveryTransport()
        wire.states["local-queue"] = ["state": "missing"]
        wire.queueError = NSError(domain: "test", code: -32091)
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "a"
        s.chat.items = [.user(id: "local-queue", text: "next", images: [])]
        s.chat.enqueueRemote(threadId: "a", text: "next", images: [], localId: "local-queue")
        for _ in 0..<60 { await Task.yield() }
        XCTAssertTrue(s.chat.failed.contains("local-queue"))
        XCTAssertNil(s.chat.pendingSend)
        XCTAssertFalse(wire.methods.contains("turn/start"))
    }
    func testFailureDoesNotBlockNextOfflineMessage() async {
        let wire = OutboxRecoveryTransport()
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "a"
        s.composer.outbox = [
            .init(threadId: "a", text: "failed", images: [], localID: "failed", state: .failed),
            .init(threadId: "a", text: "next", images: [], localID: "next")]
        s.composer.flushOutbox()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(wire.methods.contains("turn/start"))
        XCTAssertEqual(s.composer.outbox.map(\.localID), ["failed"])
        s.composer.outbox = []
    }

    func testUnknownMessagesAreNeverResubmittedOrCleared() async {
        let wire = OutboxRecoveryTransport()
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "a"
        s.composer.outbox = [.init(threadId: "b", text: "unknown", images: [], localID: "unknown", state: .awaitingAcknowledgement)]
        s.composer.flushOutbox()
        s.composer.reconcileOutbox()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertEqual(s.composer.outbox.first?.localID, "unknown")
        XCTAssertEqual(wire.methods, ["bridge/submission/status"])
        s.composer.outbox = []
    }
    func testDeliveredRecordFromAnotherChatIsReconciledWithoutSendingAgain() async {
        let wire = OutboxRecoveryTransport()
        wire.states["old"] = ["state": "accepted", "result": ["result": ["turn": ["id": "done", "status": "completed"]]]]
        let s = AppCoordinator(transport: wire)
        s.list.currentID = "a"
        s.composer.outbox = [.init(threadId: "b", text: "old", images: [], localID: "old", state: .awaitingAcknowledgement)]
        s.composer.flushOutbox()
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(s.composer.outbox.isEmpty)
        XCTAssertFalse(wire.methods.contains("turn/start"))
        s.composer.outbox = []
    }
    func testOtherChatsAndUnknownResultsDoNotCountAsUnsent() {
        let s = AppCoordinator(transport: OutboxRecoveryTransport())
        s.list.currentID = "a"
        s.composer.outbox = [
            .init(threadId: "b", text: "other", images: []),
            .init(threadId: "a", text: "unknown", images: [], state: .awaitingAcknowledgement),
            .init(threadId: "a", text: "failed", images: [], state: .failed)]
        XCTAssertEqual(s.composer.unsentCount, 0)
        s.composer.outbox.append(.init(threadId: "a", text: "offline", images: []))
        XCTAssertEqual(s.composer.unsentCount, 1)
        s.composer.outbox = []
    }

    func testClearingFailuresPreservesOtherChatsAndUncertainMessages() {
        let s = AppCoordinator(transport: OutboxRecoveryTransport())
        s.list.currentID = "a"
        s.composer.outbox = [
            .init(threadId: "a", text: "failed", images: [], localID: "failed", state: .failed),
            .init(threadId: "a", text: "unknown", images: [], localID: "unknown", state: .awaitingAcknowledgement),
            .init(threadId: "b", text: "other", images: [], localID: "other", state: .failed)]
        s.composer.clearFailedOutgoing()
        XCTAssertEqual(s.composer.outbox.map(\.localID), ["unknown", "other"])
        s.composer.outbox = []
    }
}

private final class OutboxRecoveryTransport: RPCTransport {
    var holdResume = false
    var resume: RepositoryResult?
    var defaultState = "pending"
    var queueError: Error?
    var states: [String: JSONDict] = [:]
    var methods: [String] = []
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        methods.append(method)
        if method == "thread/resume", holdResume { resume = done; return methods.count }
        if method == "thread/queue/add", let queueError { done?(.failure(queueError)); return methods.count }
        let value: JSONDict = method == "bridge/submission/status"
            ? states[params.str("clientUserMessageId") ?? ""] ?? ["state": defaultState] : ["data": []]
        done?(.success(value))
        return methods.count
    }
}

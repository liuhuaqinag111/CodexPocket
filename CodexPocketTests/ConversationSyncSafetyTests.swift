import XCTest
@testable import CodexPocket

@MainActor
final class ConversationSyncSafetyTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    private func make(_ recorder: Recorder) -> ConversationModel {
        let settings = PreferencesModel()
        let list = ThreadListModel(repository: ThreadRepository(transport: RecordingTransport()), settings: settings)
        list.currentID = "t"
        return ConversationModel(repository: recorder, settings: settings, list: list)
    }

    private func payload(_ text: String, status: String = "completed", client: String? = nil) -> JSONDict {
        var user: JSONDict = ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "hi"]]]
        if let client { user["clientId"] = client }
        let turn: JSONDict = ["id": "turn", "status": status, "startedAt": 123,
            "items": [user, ["id": "a", "type": "agentMessage", "text": text]]]
        return ["data": [turn]]
    }

    func testPollDoesNotOverlapAndStoppedGenerationCannotApply() async {
        let rec = Recorder(), chat = make(rec)
        chat.pollRemote("t"); chat.pollRemote("t")
        XCTAssertEqual(rec.calls.count, 1)
        chat.stopRemoteWatch()
        rec.calls[0].1(.success(payload("late", status: "inProgress")))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(chat.busy)
        XCTAssertTrue(chat.items.isEmpty)
    }

    func testEqualLengthPollUpdateChangesVisibleReplyWithoutExtraFullRequest() async {
        let rec = Recorder(), chat = make(rec)
        chat.pollRemote("t"); rec.calls[0].1(.success(payload("old")))
        await waitUntil { chat.items.contains(.agent(id: "a", text: "old")) }
        chat.pollRemote("t"); rec.calls[1].1(.success(payload("new")))
        await waitUntil { chat.items.contains(.agent(id: "a", text: "new")) }
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "new")))
        XCTAssertEqual(rec.calls.count, 2)
        XCTAssertTrue(rec.snapshots.isEmpty)
    }

    func testUnknownLocalTurnIgnoresOldCompletedUntilClientIdentityMatches() async {
        let rec = Recorder(), chat = make(rec)
        chat.busy = true; chat.localTurn = true; chat.sendingID = "local-new"
        chat.pollRemote("t"); rec.calls[0].1(.success(payload("old", client: "local-old")))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(chat.busy)
        XCTAssertTrue(chat.localTurn)
        chat.pollRemote("t"); rec.calls[1].1(.success(payload("new", client: "local-new")))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(chat.busy)
        XCTAssertFalse(chat.localTurn)
    }

    func testLateDiskCacheNeverReplacesNetworkOrAnotherSession() async {
        let rec = Recorder(), chat = make(rec)
        chat.open(id: "t")
        defer { chat.close() }
        XCTAssertEqual(rec.syncCacheReads, 0)
        let cached = rec.cached
        rec.calls[0].1(.success(payload("network")))
        for _ in 0..<20 { await Task.yield() }
        cached?([.agent(id: "a", text: "disk")])
        XCTAssertTrue(chat.items.contains(.agent(id: "a", text: "network")))
        chat.close()
        cached?([.agent(id: "a", text: "disk")])
        XCTAssertTrue(chat.items.isEmpty)
    }

    func testCacheRefreshDoesNotOverlapEvenAfterThrottleExpires() {
        let rec = Recorder(), chat = make(rec)
        chat.saveCache()
        chat.lastCacheAt["t"] = .distantPast
        chat.saveCache()
        XCTAssertEqual(rec.snapshots.count, 1)
    }

    func testStoppingWatchCancelsRemainingPrefetchChain() async {
        let rec = Recorder(), chat = make(rec)
        let started = expectation(description: "first prefetch started")
        rec.onSnapshot = { started.fulfill() }
        chat.prefetch(["one", "two", "three"])
        await fulfillment(of: [started], timeout: 5)
        rec.onSnapshot = nil
        XCTAssertEqual(rec.snapshots.count, 1)
        chat.stopRemoteWatch()
        rec.snapshots.first?(.success([]))
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(rec.snapshots.count, 1)
        XCTAssertNil(chat.prefetchRunning)
    }
    final class Recorder: ConversationRepositoryProtocol {
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), namespace: "sync-tests")
        var isReady = true
        var calls: [(JSONDict, RepositoryResult)] = []
        var cached: (([Item]) -> Void)?
        var snapshots: [(Result<[Item], Error>) -> Void] = []
        var onSnapshot: (() -> Void)?
        var syncCacheReads = 0
        func reconnect() {}
        func cachedItems(_ id: String) -> [Item] { syncCacheReads += 1; return [] }
        func cachedItems(_ id: String, done: @escaping ([Item]) -> Void) { cached = done }
        func refreshSnapshot(_ id: String, limit: Int, done: @escaping (Result<[Item], Error>) -> Void) {
            snapshots.append(done)
            onSnapshot?()
        }
        func perform(_ operation: ConversationOperation, done: RepositoryResult?) {
            let (method, params) = ConversationRepository.request(operation)
            if method == "thread/turns/list", let done { calls.append((params, done)) }
            else { done?(.success([:])) }
        }
    }
}

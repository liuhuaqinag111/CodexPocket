import XCTest
@testable import CodexPocket

final class RecordingTransport: RPCTransport {
    var calls: [(String, JSONDict)] = []
    var result: Result<Any, Error> = .success(["data": []] as JSONDict)
    var deferResponse = false
    var pending: RepositoryResult?
    func rpc(_ method: String, _ params: JSONDict,
             done: ((Result<Any, Error>) -> Void)?) -> Int {
        calls.append((method, params))
        if deferResponse { pending = done } else { done?(result) }
        return calls.count
    }
}

final class RepositoryBoundaryTests: XCTestCase {
    func testEmptyThreadFullSnapshotSucceeds() {
        let wire = RecordingTransport()
        wire.result = .failure(WebSocketTransport.RPCError(message:
            "thread new is not materialized yet; thread/turns/list is unavailable before first user message", code: -32600))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConversationRepository(transport: wire,
            cache: SnapshotCache(directory: directory, namespace: "empty-thread"))
        let finished = expectation(description: "empty full snapshot")
        repository.refreshSnapshot("new", limit: 6) { result in
            guard case .success(let items) = result else {
                XCTFail("Empty thread snapshot should succeed"); finished.fulfill(); return
            }
            XCTAssertTrue(items.isEmpty)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }
    func testUnmaterializedErrorStillFailsTurnStart() {
        let wire = RecordingTransport()
        let message = "thread new is not materialized yet; thread/turns/list is unavailable before first user message"
        wire.result = .failure(WebSocketTransport.RPCError(message: message, code: -32600))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConversationRepository(transport: wire,
            cache: SnapshotCache(directory: directory, namespace: "empty-thread"))
        repository.perform(.start(["threadId": "new"])) { result in
            guard case .failure(let error) = result else { XCTFail("start failure was hidden"); return }
            XCTAssertEqual(error.localizedDescription, message)
        }
    }
    func testUnmaterializedThreadHistoryIsAnEmptySuccessfulPage() {
        let wire = RecordingTransport()
        wire.result = .failure(WebSocketTransport.RPCError(message:
            "thread new is not materialized yet; thread/turns/list is unavailable before first user message", code: -32600))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory, namespace: "empty-thread")
        let repository = ConversationRepository(transport: wire, cache: cache)
        var completed = false
        repository.perform(.turns(["threadId": "new"])) { result in
            completed = true
            guard case .success(let page) = result else {
                XCTFail("A newly created empty thread must not surface an RPC error"); return
            }
            XCTAssertNotNil((page as? JSONDict)?["data"] as? [JSONDict])
            XCTAssertTrue(Protocol_.items(fromTurns: page).isEmpty)
        }
        XCTAssertTrue(completed)
    }
    func testOnlyMatchingThreadHistoryCanNormalizeUnmaterializedError() {
        let wire = RecordingTransport()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = ConversationRepository(transport: wire,
            cache: SnapshotCache(directory: directory, namespace: "empty-thread"))
        for message in ["connection reset", "thread new not found",
            "thread other is not materialized yet; thread/turns/list is unavailable before first user message"] {
            wire.result = .failure(RepositoryError(message: message))
            repository.perform(.turns(["threadId": "new"])) { result in
                guard case .failure(let error) = result else { XCTFail(message); return }
                XCTAssertEqual(error.localizedDescription, message)
            }
        }
    }
    func testCachedSnapshotCompletesAsynchronouslyOnMainAndRejectsServerSwitch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(directory: directory, namespace: "a")
        cache.save("t", Data("{\"data\":[{\"id\":\"turn\",\"items\":[{\"id\":\"answer\",\"type\":\"agentMessage\",\"text\":\"old host\"}]}]}".utf8))
        let repository = ConversationRepository(transport: RecordingTransport(), cache: cache)
        let completed = expectation(description: "async cache")
        var returned = false
        repository.cachedItems("t") { items in
            XCTAssertTrue(returned)
            XCTAssertTrue(Foundation.Thread.isMainThread)
            XCTAssertTrue(items.isEmpty)
            completed.fulfill()
        }
        cache.setNamespace("b")
        returned = true
        wait(for: [completed], timeout: 3)
    }
    func testMetadataReadRejectsAnotherThreadsIdentity() {
        let transport = RecordingTransport()
        transport.result = .success(["thread": ["id": "another", "cwd": "/repo"]] as JSONDict)
        let repository = ThreadRepository(transport: transport)
        var rejected = false
        repository.readThread("child") { if case .failure = $0 { rejected = true } }
        XCTAssertTrue(rejected)
        XCTAssertEqual(transport.calls.first?.0, "thread/read")
        XCTAssertEqual(transport.calls.first?.1.bool("includeTurns"), false)
    }
    func testFreshSnapshotIsReturnedWhenCacheCannotOpen() throws {
        let transport = RecordingTransport()
        let payload: JSONDict = ["data": [["id": "turn", "startedAt": 1234, "items": [
            ["id": "answer", "type": "agentMessage", "text": "Fresh answer"]]]]]
        transport.result = .success(payload)
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("regular file".utf8).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let cache = SnapshotCache(directory: blocked, namespace: "a")
        let repository = ConversationRepository(transport: transport, cache: cache)
        var response: Result<[Item], Error>?
        let completed = expectation(description: "snapshot")
        repository.refreshSnapshot("t", limit: 6) { response = $0; completed.fulfill() }
        wait(for: [completed], timeout: 3)
        let items = try XCTUnwrap(response).get()
        XCTAssertEqual(items.map(\.id), ["answer", "tb-turn"])
        XCTAssertFalse(cache.has("t"))
    }

    @MainActor
    func testMissingChildMetadataOpensActualAgentWithoutWriter() async throws {
        let transport = RecordingTransport()
        let store = isolatedCoordinator(transport)
        let previousHost = store.settings.host
        store.settings.host = ""
        defer { store.chat.close(); store.settings.host = previousHost }
        let root = try XCTUnwrap(Thread(json: ["id": "root", "name": "Root", "cwd": "/repo"]))
        store.list.__testSeed(threads: [root], archived: [])
        store.open(root)
        transport.result = .success(["thread": ["id": "child", "name": "Agent task",
            "cwd": "/repo/worktree", "parentThreadId": "root", "status": ["type": "idle"]]] as JSONDict)
        store.requestOpenThread("child")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.list.currentID, "child")
        XCTAssertEqual(store.chat.current?.cwd, "/repo/worktree")
        XCTAssertNil(store.pendingOpen)
        let read = try XCTUnwrap(transport.calls.first {
            $0.0 == "thread/read" && $0.1.str("threadId") == "child"
        })
        XCTAssertEqual(read.1.str("threadId"), "child")
        XCTAssertEqual(read.1.bool("includeTurns"), false)
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/resume" || $0.0 == "turn/start" })
    }

    @MainActor
    func testMissingThreadFailureLeavesCurrentChatAndReportsError() async throws {
        let transport = RecordingTransport()
        let store = isolatedCoordinator(transport)
        let previousHost = store.settings.host
        store.settings.host = ""
        defer { store.chat.close(); store.settings.host = previousHost }
        let root = try XCTUnwrap(Thread(json: ["id": "root", "cwd": "/repo"]))
        store.list.__testSeed(threads: [root], archived: [])
        store.open(root)
        transport.result = .failure(RepositoryError(message: "missing child"))
        store.requestOpenThread("missing")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.list.currentID, "root")
        XCTAssertNil(store.list.thread("missing"))
        XCTAssertNil(store.pendingOpen)
        XCTAssertTrue(store.banner?.contains("missing child") == true)
    }

    @MainActor
    func testLateChildMetadataCannotReplaceNewerNavigation() async throws {
        let transport = RecordingTransport()
        let store = isolatedCoordinator(transport)
        let previousHost = store.settings.host
        store.settings.host = ""
        defer { store.chat.close(); store.settings.host = previousHost }
        let root = try XCTUnwrap(Thread(json: ["id": "root", "cwd": "/repo"]))
        store.list.__testSeed(threads: [root], archived: [])
        store.open(root)
        transport.deferResponse = true
        store.requestOpenThread("child")
        let pending = try XCTUnwrap(transport.pending)
        store.open(root)
        pending(.success(["thread": ["id": "child", "cwd": "/repo"]] as JSONDict))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.list.currentID, "root")
        XCTAssertNil(store.list.thread("child"))
        XCTAssertNil(store.pendingOpen)
    }

    @MainActor
    private func isolatedCoordinator(_ transport: RecordingTransport) -> AppCoordinator {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SnapshotCache(directory: directory, namespace: "navigation-test")
        return AppCoordinator(transport: transport, cache: cache)
    }
    func testSnapshotRepositoryReturnsAndCachesTypedItems() {
        let transport = RecordingTransport()
        let payload: JSONDict = ["data": [["id": "turn", "startedAt": 1234, "items": [
            ["id": "reason", "type": "reasoning", "summary": ["Plan"]],
            ["id": "answer", "type": "agentMessage", "text": "Done"]]]]]
        transport.result = .success(payload)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SnapshotCache(directory: directory, namespace: "a")
        let repository = ConversationRepository(transport: transport, cache: cache)
        var result: [Item] = []
        let completed = expectation(description: "snapshot")
        repository.refreshSnapshot("t", limit: 6) { if case .success(let items) = $0 { result = items }; completed.fulfill() }
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(result.map(\.id), ["reason", "answer", "tb-turn"])
        XCTAssertEqual(repository.cachedItems("t"), result)
        XCTAssertEqual(transport.calls.first?.1.str("itemsView"), "full")
    }

    func testLateSnapshotIsRejectedAfterServerSwitch() {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SnapshotCache(directory: directory, namespace: "a")
        let repository = ConversationRepository(transport: transport, cache: cache)
        var rejected = false
        let completed = expectation(description: "snapshot rejection")
        repository.refreshSnapshot("t", limit: 6) { result in
            if case .failure = result { rejected = true }
            completed.fulfill()
        }
        cache.setNamespace("b")
        transport.pending?(.success(["data": []] as JSONDict))
        wait(for: [completed], timeout: 3)
        XCTAssertTrue(rejected)
        XCTAssertFalse(cache.has("t"))
    }

    @MainActor
    func testViewingHistoryNeverAcquiresWriter() async throws {
        let transport = RecordingTransport()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SnapshotCache(directory: directory, namespace: "test")
        let preferences = PreferencesModel()
        let previousHost = preferences.host
        preferences.host = ""
        defer { preferences.host = previousHost }
        let list = ThreadListModel(repository: ThreadRepository(transport: transport), settings: preferences)
        let model = ConversationModel(repository: ConversationRepository(transport: transport, cache: cache),
                                      settings: preferences, list: list)
        let thread = try XCTUnwrap(Thread(json: ["id": "readonly", "cwd": "/repo"]))
        list.__testSeed(threads: [thread], archived: [])
        model.open(thread)
        await Task.yield()
        XCTAssertTrue(transport.calls.contains { $0.0 == "thread/turns/list" })
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/resume" || $0.0 == "turn/start" })
        model.close()
    }

    func testConversationRepositoryPreservesFullHistoryRequest() {
        let transport = RecordingTransport()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = SnapshotCache(directory: directory, namespace: "test")
        let repository = ConversationRepository(transport: transport, cache: cache)
        repository.perform(.turns(["threadId": "t", "itemsView": "full", "limit": 12]))
        XCTAssertEqual(transport.calls.first?.0, "thread/turns/list")
        XCTAssertEqual(transport.calls.first?.1.str("itemsView"), "full")
        XCTAssertEqual(transport.calls.first?.1.int("limit"), 12)
    }
}

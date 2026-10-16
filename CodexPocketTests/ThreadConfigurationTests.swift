import XCTest
@testable import CodexPocket

@MainActor
final class ThreadConfigurationTests: XCTestCase {
    func testEffortUsesWireFieldAndPreservesDefaultForArchivedThread() {
        let rpc = RecordingTransport(), settings = PreferencesModel()
        let old = settings.defaultEffort
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: settings)
        list.archived = [Thread(json: ["id": "a", "model": "m"])!]
        list.currentID = "a"
        list.setEffort("high")
        XCTAssertEqual(rpc.calls.first?.1.str("effort"), "high")
        XCTAssertNil(rpc.calls.first?.1["reasoningEffort"])
        XCTAssertEqual(list.archived.first?.effort, "high")
        XCTAssertEqual(settings.defaultEffort, old)
    }

    func testSettingsNotificationUpdatesArchivedAndPendingRowsAndClearsEffort() {
        let list = ThreadListModel(repository: ThreadRepository(transport: RecordingTransport()), settings: PreferencesModel())
        let row = Thread(json: ["id": "a", "model": "old", "reasoningEffort": "high"])!
        list.archived = [row]; list.pendingNew["a"] = (row, Date())
        list.applyConfigurationEvent(["threadId": "a", "threadSettings": ["model": "new", "effort": NSNull()]])
        XCTAssertEqual(list.archived.first?.model, "new")
        XCTAssertEqual(list.archived.first?.effort, "")
        XCTAssertEqual(list.pendingNew["a"]?.0.effort, "")
    }
    func testFirstMessageRunsAfterCreationCallbackThroughSendHook() async {
        let rpc = RecordingTransport(); rpc.deferResponse = true
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        var events: [String] = []
        list.onFirstMessage = { id, text in events.append("send:\(id):\(text)") }
        list.create(cwd: "/tmp", model: "chosen", effort: "high", first: "hello") {
            events.append("open:\($0 ?? "nil")")
        }
        XCTAssertEqual(rpc.calls[0].1.dict("config")?.str("model_reasoning_effort"), "high")
        XCTAssertNil(rpc.calls[0].1["reasoningEffort"])
        let reply = rpc.pending
        reply?(.success(["thread": ["id": "created", "cwd": "/tmp"]]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(events, ["open:created", "send:created:hello"])
        XCTAssertFalse(rpc.calls.contains { $0.0 == "turn/start" })
    }
}

import XCTest
@testable import CodexPocket

@MainActor
final class DesktopQueueRegressionTests: XCTestCase {
    func testUnknownDesktopWriterWithRealInvalidRequestCodeQueues() async throws {
        for message in ["thread not found: desktop-thread",
                        "thread desktop-thread already has an active writer"] {
            let (store, transport) = heldConversation()
            defer { store.chat.close() }
            store.chat.steer("手机下一句", localID: "local-desktop")
            let reply = try XCTUnwrap(transport.pending)
            XCTAssertEqual(transport.calls.first?.0, "turn/steer")
            transport.deferResponse = false
            reply(.failure(NSError(domain: "RPC", code: -32600,
                userInfo: [NSLocalizedDescriptionKey: message])))
            for _ in 0..<30 { await Task.yield() }
            let queued = transport.calls.filter { $0.0 == "thread/queue/add" }
            XCTAssertEqual(queued.count, 1, message)
            XCTAssertEqual(queued.first?.1.str("clientUserMessageId"), "local-desktop")
            XCTAssertFalse(store.chat.failed.contains("local-desktop"))
            XCTAssertTrue(store.chat.desktopLocked)
            XCTAssertFalse(transport.calls.contains { $0.0 == "turn/start" })
        }
    }

    func testInvalidSteerParametersStillFailWithoutQueue() async throws {
        let (store, transport) = heldConversation()
        defer { store.chat.close() }
        store.chat.steer("手机下一句", localID: "local-invalid")
        let reply = try XCTUnwrap(transport.pending)
        transport.deferResponse = false
        reply(.failure(NSError(domain: "RPC", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Invalid request: missing expectedTurnId"])))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(store.chat.failed.contains("local-invalid"))
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/add" })
    }

    func testIdleDesktopWriterDoesNotLeaveUndrainableQueue() async throws {
        let (store, transport) = heldConversation(busy: false)
        defer { store.chat.close() }
        store.chat.steer("手机下一句", localID: "local-idle")
        let reply = try XCTUnwrap(transport.pending)
        transport.deferResponse = false
        reply(.failure(NSError(domain: "RPC", code: -32600,
            userInfo: [NSLocalizedDescriptionKey: "thread desktop-thread already has an active writer"])))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(store.chat.sendStates["local-idle"],
                       .failed("会话仍被电脑端占用，释放后重试"))
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/add" })
    }

    private func heldConversation(busy: Bool = true) -> (AppCoordinator, RecordingTransport) {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), namespace: "desktop-queue-test")
        let store = AppCoordinator(transport: transport, cache: cache)
        store.list.currentID = "desktop-thread"
        store.chat.busy = busy
        store.chat.localTurn = false
        store.chat.desktopLocked = false
        store.chat.serverTurnId = "desktop-turn"
        return (store, transport)
    }
}

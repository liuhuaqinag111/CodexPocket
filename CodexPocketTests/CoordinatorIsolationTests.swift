import XCTest
import Combine
@testable import CodexPocket

final class CoordinatorIsolationTests: XCTestCase {
    @MainActor
    func testResolvedStringRequestRemovesOnlyMatchingApproval() async {
        let store = AppCoordinator(transport: RecordingTransport())
        store.list.currentID = "t"
        for id in ["wire-a", "wire-b"] {
            store.rpc.handle("{\"id\":\"\(id)\",\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"threadId\":\"t\",\"itemId\":\"i\"}}")
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.chat.approvals.count, 2)
        store.rpc.onNotification?("bridge/approvalResolved", ["requestId": "wire-a"])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.chat.approvals.map(\.requestID), ["wire-b"])
    }
    @MainActor
    func testStreamDoesNotInvalidateEntireAppButBannerDoes() async {
        let s = AppCoordinator(transport: RecordingTransport())
        var count = 0
        let token = s.objectWillChange.sink { count += 1 }
        for i in 0..<50 { s.chat.items = [.agent(id: "a", text: String(i))] }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(count, 0)
        s.chat.banner = "出错"
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(count, 0)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testComposerReceivesActionChangeWithoutContentUpdates() async {
        let s = AppCoordinator(transport: RecordingTransport())
        s.list.currentID = "t"
        s.composer.text = "插话"
        for _ in 0..<10 { await Task.yield() }
        var count = 0
        let token = s.composer.objectWillChange.sink { count += 1 }
        s.chat.busy = true
        for _ in 0..<10 { await Task.yield() }
        XCTAssertGreaterThan(count, 0)
        let before = count
        s.chat.items = [.agent(id: "a", text: "回复")]
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(count, before)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testSwitchingServerClearsVisibleOldThreadAndPendingWork() {
        let cache = AppCoordinator.makeCache(namespace: "old")
        let store = AppCoordinator(transport: RecordingTransport(), cache: cache)
        store.list.currentID = "same-id"
        store.list.threads = [Thread(json: ["id": "same-id", "name": "旧电脑"])!]
        store.chat.items = [.agent(id: "old-message", text: "旧消息")]
        store.chat.activeSubmissionIDs.insert("old-submit")
        store.prepareConnection(namespace: "new")
        XCTAssertNil(store.list.currentID)
        XCTAssertTrue(store.list.threads.isEmpty)
        XCTAssertTrue(store.chat.items.isEmpty)
        XCTAssertTrue(store.chat.activeSubmissionIDs.isEmpty)
        XCTAssertEqual(cache.namespace, "new")
    }
}

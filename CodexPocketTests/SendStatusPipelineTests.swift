import XCTest
@testable import CodexPocket

final class SendStatusPipelineTests: XCTestCase {

    @MainActor
    func testSendPipelineTransitions() {
        let store = AppCoordinator()
        let localId = "local-m1"
        store.chat.items = [.user(id: localId, text: "你好", images: [])]
        store.chat.markSending(localId, since: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(store.chat.sendStates[localId]?.since, Date(timeIntervalSince1970: 100))

        store.chat.markQueued(localId)
        XCTAssertEqual(store.chat.sendStates[localId]?.isQueued, true)

        store.chat.fail(localId, "上游断开")
        XCTAssertEqual(store.chat.sendStates[localId]?.isFailed, true)

        store.chat.accept(localId)
        XCTAssertNil(store.chat.sendStates[localId])
    }
}

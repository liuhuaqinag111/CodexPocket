import XCTest
@testable import CodexPocket

final class ConnectionDiagnosticsTests: XCTestCase {
    @MainActor
    func testWriterReleaseFeedbackDoesNotClaimSuccessWithRemainingWorkers() {
        XCTAssertEqual(AppCoordinator.writerReleaseFeedback(["released": true, "writerWorkers": 1]),
                       "仍有任务或请求未结束，空闲后会自动释放")
        XCTAssertEqual(AppCoordinator.writerReleaseFeedback(["released": false, "reason": "active-turn"]),
                       "仍有回复正在生成，结束后会自动释放")
        XCTAssertEqual(AppCoordinator.writerReleaseFeedback(["released": true, "writerWorkers": 0]),
                       "已释放空闲会话，连接保持正常")
        XCTAssertEqual(AppCoordinator.writerReleaseFeedback(["released": false, "reason": "busy-or-unverified"]),
                       "当前状态还没确认，暂不释放；稍后再试")
    }

    @MainActor
    func testSnapshotContainsAllDiagnosticFields() {
        let rpc = WebSocketTransport()
        let diag = rpc.diagnosticSnapshot(now: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(diag.stateLabel, "未连接")
        XCTAssertEqual(diag.drops, 0)
        XCTAssertEqual(diag.connects, 0)
        XCTAssertEqual(diag.lastDropReason, "-")
        XCTAssertFalse(diag.summaryLine.isEmpty)
    }

    @MainActor
    func testFormatReconnectCountdown() {
        let text = WebSocketTransport.reconnectCountdownText(secondsRemaining: 3)
        XCTAssertEqual(text, "3秒后重试")
        let immediate = WebSocketTransport.reconnectCountdownText(secondsRemaining: 0)
        XCTAssertEqual(immediate, "正在连接…")
    }

    @MainActor
    func testHeartbeatRecordsLastReceivedTime() {
        let rpc = WebSocketTransport()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        rpc.recordIncomingTraffic(at: t0)
        let snapshot = rpc.diagnosticSnapshot(now: t0.addingTimeInterval(5))
        XCTAssertEqual(snapshot.idleSeconds, 5)
    }
}

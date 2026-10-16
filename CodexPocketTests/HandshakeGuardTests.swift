import XCTest
@testable import CodexPocket

final class TestSocket: RPCSocket {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode
    var maximumMessageSize = 0
    var status: URLSessionTask.State = .suspended
    var receiver: ((Result<Message, Error>) -> Void)?
    var sends: [(Error?) -> Void] = []
    var frames: [JSONDict] = []
    var onCancel: (() -> Void)?
    var state: URLSessionTask.State { status }
    func resume() { status = .running }
    func cancel(with closeCode: CloseCode, reason: Data?) {
        status = .canceling
        onCancel?()
    }
    func receive(completionHandler: @escaping (Result<Message, Error>) -> Void) {
        receiver = completionHandler
    }
    func send(_ message: Message, completionHandler: @escaping (Error?) -> Void) {
        if case .string(let text) = message, let obj = JSON.object(text) { frames.append(obj) }
        sends.append(completionHandler)
    }
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {}
}

final class TestSocketSession {
    var sockets: [TestSocket] = []
    func webSocketTask(with request: URLRequest) -> RPCSocket {
        let socket = TestSocket()
        sockets.append(socket)
        return socket
    }
}

/// 「动不动就断」的一个主因：**在途的握手被自己拆掉**。
///
/// `reconnectNow()` 会被"发送失败重试"那条路每 1.5 秒调一次
/// （`ConversationModel.startTurn` 6 次 / `ThreadListModel.create` 8 次），
/// 而一次握手本来就要 1~2 秒。以前每次调用都 cancel + 重开，
/// 于是**越重试越连不上**，一直卡在握手，日志上是一串活不过几秒的 1006。
/// 真机实测抓到过 `lastDrop = init:连接已断开`，就是这个循环。
final class HandshakeGuardTests: XCTestCase {

    private func drainCallbacks() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func open(_ rpc: WebSocketTransport, token: String = "test") {
        rpc.connect(url: URL(string: "wss://example.invalid/ws")!, token: token)
    }

    private func ready(_ socket: TestSocket) {
        let id = socket.frames.first!.int("id")!
        socket.receiver?(.success(.string("{\"id\":\(id),\"result\":{}}")))
        drainCallbacks()
    }

    func testReplacingHandshakeIgnoresOldFailure() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        open(rpc)
        let old = session.sockets[0]
        open(rpc, token: "changed")
        XCTAssertEqual(session.sockets.count, 2)
        old.receiver?(.failure(URLError(.cancelled)))
        drainCallbacks()
        XCTAssertEqual(rpc.state, .connecting)
    }

    func testOldResponseCannotMakeReplacementReady() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        open(rpc)
        let old = session.sockets[0]
        open(rpc, token: "changed")
        ready(old)
        XCTAssertEqual(rpc.state, .connecting)
        XCTAssertEqual(rpc.connects, 0)
    }

    func testSendErrorFinishesOnlyMatchingRequest() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        open(rpc)
        ready(session.sockets[0])
        var completions = 0
        rpc.rpc("thread/list") { result in
            if case .failure = result { completions += 1 }
        }
        let failedSend = session.sockets[0].sends.last!
        var otherFinished = false
        rpc.rpc("model/list") { _ in otherFinished = true }
        failedSend(URLError(.networkConnectionLost))
        drainCallbacks()
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(otherFinished)
        XCTAssertEqual(rpc.state, .ready)
        rpc.disconnect()
        XCTAssertEqual(completions, 1)
    }

    func testReceiveFailureSchedulesRetryOnMainQueue() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        open(rpc)
        ready(session.sockets[0])
        let changed = expectation(description: "retry state")
        rpc.onState = { state in
            if case .reconnecting = state {
                XCTAssertTrue(Foundation.Thread.isMainThread)
                changed.fulfill()
            }
        }
        let receive = session.sockets[0].receiver
        DispatchQueue.global().async { receive?(.failure(URLError(.networkConnectionLost))) }
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(rpc.drops, 1)
    }

    func testConcurrentProbesSendOnePing() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        open(rpc)
        ready(session.sockets[0])
        rpc.probe()
        rpc.probe()
        XCTAssertEqual(session.sockets[0].frames.filter { $0.str("method") == "bridge/ping" }.count, 1)
    }

    func testSuspensionResumesButUserDisconnectDoesNot() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        open(rpc)
        rpc.suspend()
        rpc.reconnectNow()
        XCTAssertEqual(session.sockets.count, 1)
        rpc.resume()
        XCTAssertEqual(session.sockets.count, 2)
        XCTAssertEqual(rpc.state, .connecting)
        rpc.suspend()
        rpc.disconnect()
        rpc.resume()
        XCTAssertEqual(session.sockets.count, 2)
        XCTAssertEqual(rpc.state, .idle)
    }

    /// 已经连上了：不该重开。
    func testReadyDoesNotReopen() {
        XCTAssertFalse(WebSocketTransport.shouldReopen(ready: true, hasTask: true,
                                              taskRunning: true, attemptAge: 0.1))
    }

    /// 没有 socket：必须开一条。
    func testNoTaskReopens() {
        XCTAssertTrue(WebSocketTransport.shouldReopen(ready: false, hasTask: false,
                                             taskRunning: false, attemptAge: nil))
    }

    /// **正在握手（刚起步）：不能拆。** 这就是那个 bug。
    func testInFlightHandshakeIsLeftAlone() {
        XCTAssertFalse(WebSocketTransport.shouldReopen(ready: false, hasTask: true,
                                              taskRunning: true, attemptAge: 1.5),
                       "在途的握手被拆了 —— 每 1.5 秒重试一次就永远握不上手")
        XCTAssertFalse(WebSocketTransport.shouldReopen(ready: false, hasTask: true,
                                              taskRunning: true, attemptAge: 7.9))
    }

    /// 握太久还没成：该推倒重来。
    func testStaleHandshakeReopens() {
        XCTAssertTrue(WebSocketTransport.shouldReopen(ready: false, hasTask: true,
                                             taskRunning: true, attemptAge: 9))
    }

    /// socket 已经不在跑了：立刻重开。
    func testDeadTaskReopens() {
        XCTAssertTrue(WebSocketTransport.shouldReopen(ready: false, hasTask: true,
                                             taskRunning: false, attemptAge: 1))
    }

    /// 没连上时 probe 不该插手（那是握手看门狗的活）。
    @MainActor
    func testProbeIsNoopBeforeReady() {
        let rpc = WebSocketTransport()
        XCTAssertEqual(rpc.state, .idle)
        rpc.probe()          // 不能崩，也不该改状态
        XCTAssertEqual(rpc.state, .idle)
    }
}

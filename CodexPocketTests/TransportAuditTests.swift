import XCTest
@testable import CodexPocket

final class TransportAuditTests: XCTestCase {
    func testSocketJSONParsingWaitsOffMainAndDeliversOnMain() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket
        defer { rpc.disconnect() }
        let delivered = expectation(description: "decoded frame")
        var methods: [String] = []
        rpc.onNotification = { method, _ in
            XCTAssertTrue(Foundation.Thread.isMainThread)
            methods.append(method); delivered.fulfill()
        }
        rpc.incoming.suspend()
        rpc.listen()
        socket.receiver?(.success(.string("{\"method\":\"first\"}")))
        DispatchQueue.main.async {
            XCTAssertTrue(methods.isEmpty, "JSON 尚在后台队列等待，主线程不应自行解码")
            rpc.incoming.resume()
        }
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(methods, ["first"])
    }
    func testBusinessRequestWaitsForInitialize() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        rpc.connect(url: URL(string: "wss://example.invalid/ws")!, token: "test")
        var failed = false
        rpc.rpc("turn/start") { if case .failure = $0 { failed = true } }
        XCTAssertTrue(failed)
        XCTAssertEqual(session.sockets[0].frames.compactMap { $0.str("method") }, ["initialize"])
    }

    func testDecodedFrameFromDetachedSocketCannotReachNewConnection() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket
        let drained = expectation(description: "old parser drained")
        var notifications = 0
        rpc.onNotification = { _, _ in notifications += 1 }
        rpc.incoming.suspend()
        rpc.listen()
        socket.receiver?(.success(.string("{\"method\":\"old-frame\"}")))
        rpc.disconnect()
        let replacement = TestSocket(); replacement.resume(); rpc.task = replacement
        rpc.incoming.async { DispatchQueue.main.async { drained.fulfill() } }
        rpc.incoming.resume()
        wait(for: [drained], timeout: 3)
        XCTAssertEqual(notifications, 0)
        XCTAssertNil(replacement.receiver)
        rpc.disconnect()
    }

    func testConnectionIdentityChangesOnlyForAnotherTargetOrToken() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        let url = URL(string: "wss://example.invalid/ws")!
        rpc.connect(url: url, token: "one")
        let original = rpc.connectionIdentity
        rpc.connect(url: url, token: "one")
        XCTAssertEqual(rpc.connectionIdentity, original)
        rpc.connect(url: url, token: "two")
        XCTAssertNotEqual(rpc.connectionIdentity, original)
        let changedToken = rpc.connectionIdentity
        rpc.connect(url: URL(string: "wss://other.invalid/ws")!, token: "two")
        XCTAssertNotEqual(rpc.connectionIdentity, changedToken)
    }

    func testUnknownServerRequestReturnsMethodError() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket; rpc.state = .ready
        defer { rpc.disconnect() }
        rpc.handleServerRequest(id: 44, method: "unknown/request", params: [:])
        XCTAssertEqual(socket.frames.last?.dict("error")?.int("code"), -32601)
        XCTAssertNil(socket.frames.last?["result"])
    }

    func testServerErrorCodeSurvivesCallback() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket; rpc.state = .ready
        defer { rpc.disconnect() }
        for code in [-32091, -32092, -32093] {
            var received: Int?
            let id = rpc.rpc("turn/start") { result in
                if case .failure(let error) = result { received = (error as NSError).code }
            }
            rpc.handle("{\"id\":\(id),\"error\":{\"code\":\(code),\"message\":\"routing failed\"}}")
            XCTAssertEqual(received, code)
        }
    }

    func testLateOldSocketTrafficCannotRefreshHeartbeat() {
        let session = TestSocketSession()
        let rpc = WebSocketTransport(makeTask: session.webSocketTask)
        defer { rpc.disconnect() }
        let url = URL(string: "wss://example.invalid/ws")!
        rpc.connect(url: url, token: "one")
        let old = session.sockets[0]
        rpc.connect(url: url, token: "two")
        let past = Date(timeIntervalSince1970: 1)
        rpc.lastPong = past
        old.receiver?(.success(.string("{\"method\":\"bridge/pong\"}")))
        XCTAssertEqual(rpc.lastPong, past)
    }

    func testSynchronousCancellationSeesDetachedSocket() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket
        var detached = false
        socket.onCancel = { detached = rpc.task == nil }
        rpc.disconnect()
        XCTAssertTrue(detached)
    }

    func testStringServerRequestPreservesExactReplyID() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket; rpc.state = .ready
        defer { rpc.disconnect() }
        rpc.handle("{\"id\":\"request-7\",\"method\":\"unknown/request\",\"params\":{}}")
        XCTAssertEqual(socket.frames.last?.str("id"), "request-7")
        XCTAssertEqual(socket.frames.last?.dict("error")?.int("code"), -32601)
    }

    func testStringApprovalReplaysOneIdentityAndRepliesToOriginalID() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket; rpc.state = .ready
        defer { rpc.disconnect() }
        var approvals: [Approval] = []
        rpc.onApproval = { approvals.append($0) }
        let request = "{\"id\":\"callback-1\",\"method\":\"execCommandApproval\",\"params\":{\"conversationId\":\"thread-b\",\"callId\":\"item-a\",\"command\":[\"echo\",\"ok\"]}}"
        rpc.handle(request); rpc.handle(request)
        XCTAssertEqual(approvals.count, 2)
        guard let approval = approvals.first else { return }
        XCTAssertEqual(approvals.last?.id, approval.id)
        XCTAssertEqual(approval.itemId, "item-a")
        XCTAssertEqual(approval.detail, "echo ok")
        XCTAssertEqual(approval.threadId, "thread-b")
        XCTAssertEqual(approval.requestID, "callback-1")
        XCTAssertEqual(approval.decision(accept: true), "approved")
        XCTAssertEqual(approval.decision(accept: false), "abort")
        rpc.reply(to: approval.id, result: ["decision": "approved"])
        XCTAssertEqual(socket.frames.last?.str("id"), "callback-1")
    }

    func testModernApprovalUsesModernDecisionSchema() {
        let rpc = WebSocketTransport()
        var approval: Approval?
        rpc.onApproval = { approval = $0 }
        rpc.handleServerRequest(id: -2_000_001, method: "item/commandExecution/requestApproval",
            params: ["threadId": "thread-a", "itemId": "item-a", "approvalId": "subcommand"])
        XCTAssertEqual(approval?.decision(accept: true), "accept")
        XCTAssertEqual(approval?.decision(accept: false), "decline")
        XCTAssertEqual(approval?.threadId, "thread-a")
        XCTAssertEqual(approval?.approvalID, "subcommand")
    }

    func testUserInputRequestIsNotRejectedAsUnknownMethod() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket; rpc.state = .ready
        defer { rpc.disconnect() }
        rpc.handleServerRequest(id: 70, method: "item/tool/requestUserInput", params: [
            "threadId": "thread-a", "turnId": "turn-a", "itemId": "item-a", "isBlocking": true,
            "questions": [["id": "q", "header": "目标", "question": "选择目标",
                "options": [["label": "A", "description": "选项 A"]]]]])
        XCTAssertTrue(socket.frames.isEmpty, "用户输入请求必须显示表单，不能立即返回未知方法")
    }

    func testUserInputAnswerUsesOriginalRequestAndAllQuestionIDs() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket; rpc.state = .ready
        defer { rpc.disconnect() }
        var request: ServerQuestionRequest?
        rpc.onUserInput = { request = $0 }
        let json = "{\"id\":\"input-70\",\"method\":\"item/tool/requestUserInput\",\"params\":{\"threadId\":\"t\",\"turnId\":\"u\",\"itemId\":\"i\",\"isBlocking\":true,\"questions\":[{\"id\":\"choice\",\"header\":\"选择\",\"question\":\"选一个\",\"options\":[{\"label\":\"A\",\"description\":\"选项A\"}]},{\"id\":\"secret\",\"header\":\"令牌\",\"question\":\"输入令牌\",\"isSecret\":true}]}}"
        rpc.handle(json)
        guard let request else { return XCTFail("request missing") }
        XCTAssertTrue(request.questions.last?.isSecret == true)
        XCTAssertFalse(rpc.reply(to: request, answers: ["choice": ["A"]]))
        XCTAssertTrue(rpc.reply(to: request, answers: ["choice": ["A"], "secret": ["value"]]))
        XCTAssertEqual(socket.frames.last?.str("id"), "input-70")
        let result = socket.frames.last?.dict("result")?.dict("answers")
        XCTAssertEqual(result?.dict("secret")?.strs("answers"), ["value"])
        XCTAssertNil(socket.frames.last?["method"])
    }

    func testOtherAnswerIsAllowedOnlyWhenQuestionPermitsIt() {
        var question: JSONDict = ["id": "q", "header": "选择", "question": "选一个",
            "options": [["label": "A", "description": "选项 A"]]]
        func request() -> ServerQuestionRequest? {
            ServerQuestionRequest(id: 1, requestID: nil, params: ["threadId": "t", "turnId": "u",
                "itemId": "i", "isBlocking": false, "questions": [question]])
        }
        XCTAssertNil(request()?.result(answers: ["q": ["other text"]]))
        question["isOther"] = true
        XCTAssertNotNil(request()?.result(answers: ["q": ["other text"]]))
        XCTAssertNil(request()?.result(answers: ["q": ["  "]]))
    }

    func testMalformedUserInputRequestGetsInvalidParamsResponse() {
        let socket = TestSocket(); socket.resume()
        let rpc = WebSocketTransport(); rpc.task = socket; rpc.state = .ready
        defer { rpc.disconnect() }
        rpc.handleServerRequest(id: 71, method: "item/tool/requestUserInput", params: [:])
        XCTAssertEqual(socket.frames.last?.int("id"), 71)
        XCTAssertEqual(socket.frames.last?.dict("error")?.int("code"), -32602)
    }
}

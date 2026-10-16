import XCTest

/// 仅连接 18182 的本机样例，服务端请求和响应均可独立核对。
final class AwardStateTests: XCTestCase {
    private let app = XCUIApplication()
    private let base = "http://127.0.0.1:18182/"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let fixture = try control("reset")
        let id = try XCTUnwrap(fixture["threadId"] as? String)
        app.launchEnvironment = ["CODEX_PHONE_HOST": "127.0.0.1",
            "CODEX_PHONE_PORT": "18182", "CODEX_PHONE_TOKEN": "mock",
            "CODEX_PHONE_OPEN": id]
        app.launchArguments = ["-draft.v2.ws://127.0.0.1:18182/ws." + id, ""]
        app.launch()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Allow"].waitForExistence(timeout: 2) {
            system.buttons["Allow"].tap()
        }
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["image.open"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.descendants(matching: .any)
            .matching(identifier: "chat.agent").count, 3,
            "空白 agent 占位不应渲染成只有 Codex 标题的行")
    }

    override func tearDownWithError() throws { app.terminate() }

    func testApprovalAcceptAndDeclineReplyAndDisappear() throws {
        for (action, decision) in [("allow", "accept"), ("deny", "decline")] {
            _ = try control("emit/approval-" + action)
            let button = app.buttons["approval." + action].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8))
            XCTAssertEqual(button.label, action == "allow" ? "允许" : "拒绝")
            reveal(button)
            try screenshot("approval-" + action + "-pending")
            tap("approval." + action)
            disappeared(app.buttons["approval.allow"].firstMatch)
            disappeared(app.buttons["approval.deny"].firstMatch)
            let reply = try response("award-approval-" + action)
            XCTAssertEqual(reply["decision"] as? String, decision)
            try screenshot("approval-" + action + "-resolved")
        }
    }

    func testQuestionSelectionSubmitsOriginalRequestAndDisappears() throws {
        _ = try control("emit/question")
        let submit = app.buttons["userInput.submit"]
        let appears = submit.waitForExistence(timeout: 8)
        try screenshot("question-pending")
        try app.debugDescription.write(toFile: "/tmp/codexpocket-question-tree.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(appears)
        XCTAssertFalse(submit.isEnabled)
        let option = app.buttons.matching(identifier: "userInput.option.approach").firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 8))
        XCTAssertTrue(option.label.contains("先检查布局"), option.label)
        reveal(option)
        option.tap()
        XCTAssertTrue(submit.isEnabled)
        try screenshot("question-selected")
        tap("userInput.submit")
        disappeared(submit)
        disappeared(option)
        let reply = try response("award-question")
        let answers = try XCTUnwrap(reply["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers, ["approach": ["answers": ["先检查布局"]]])
        try screenshot("question-submitted")
    }

    func testAssistantImageOpensAndCloses() throws {
        XCTAssertEqual(app.buttons["image.open"].firstMatch.label, "查看图片")
        try screenshot("image-thumbnail")
        tap("image.open")
        let close = app.buttons["viewer.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        XCTAssertEqual(close.label, "关闭图片")
        XCTAssertTrue(app.buttons["viewer.save"].exists)
        try screenshot("image-fullscreen")
        close.tap()
        disappeared(close)
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["image.open"].firstMatch.exists)
        try screenshot("image-closed")
    }

    func testOriginalImageFailureDisablesSaveAndRetryRecovers() throws {
        _ = try control("image/fail")
        tap("image.open")
        let retry = app.buttons["viewer.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["viewer.save"].isEnabled)
        try screenshot("image-original-failed")
        _ = try control("image/slow")
        retry.tap()
        XCTAssertTrue(app.staticTexts["正在加载原图…"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["viewer.save"].isEnabled)
        try screenshot("image-original-loading")
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: app.buttons["viewer.save"])
        waitForExpectations(timeout: 10)
        try screenshot("image-original-ready")
        app.buttons["viewer.close"].tap()
    }

    func testPlanUpdatesAndUsageValues() throws {
        _ = try control("emit/plan")
        let step = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "核对手机布局")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 8))
        XCTAssertEqual(step.value as? String, "进行中")
        XCTAssertTrue(app.staticTexts["1/2"].exists)
        try screenshot("plan-running")
        _ = try control("emit/plan-complete")
        let finished = expectation(for: NSPredicate(format: "value == %@", "已完成"), evaluatedWith: step)
        wait(for: [finished], timeout: 8)
        XCTAssertTrue(app.staticTexts["2/2"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "chat.plan").count, 1)
        try screenshot("plan-completed")
        _ = try control("emit/usage")
        tap("chat.title")
        tap("本会话用量")
        XCTAssertTrue(app.staticTexts["上下文占用 25%"].waitForExistence(timeout: 8))
        for value in ["24.0k", "18.0k", "6.0k", "4.0k", "2.0k", "96.0k"] {
            XCTAssertTrue(app.staticTexts[value].exists, value)
        }
        try screenshot("usage-populated")
    }

    func testScrollSendAndKeyboardDismissStayAtLatest() throws {
        try openScrollHistory()
        try screenshot("scroll-v709-open-long-history")
        typeScrollMessage()
        waitUntil("键盘展开时仍贴底") { self.metric("y") <= 40 }
        try screenshot("scroll-v709-keyboard-expanded")
        let beforeSend = metric("ag")
        app.buttons["composer.send"].tap()
        waitUntil("发送后键盘收起") { self.app.keyboards.count == 0 }
        waitUntil("合成回合已运行且贴底") {
            self.metric("busy") == 1 && self.metric("ag") > beforeSend && self.metric("y") <= 40
        }
        try screenshot("scroll-v709-sent-keyboard-dismissed")
        for _ in 0..<6 {
            let previous = metric("ag")
            _ = try control("scroll/grow")
            waitUntil("回复增长后贴底") {
                self.metric("ag") > previous && self.metric("y") <= 40
            }
            XCTAssertEqual(metric("bot"), 1)
        }
        _ = try control("scroll/complete")
        assertPinnedForTwoSeconds()
        try screenshot("scroll-v709-completed-pinned")
    }

    func testExpandingProcessKeepsTheTappedHeaderVisible() throws {
        app.terminate()
        let fixture = try control("scroll/process")
        app.launchEnvironment["CODEX_PHONE_OPEN"] = try XCTUnwrap(fixture["threadId"] as? String)
        app.launch()
        let group = app.buttons["chat.workGroup"].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        reveal(group)
        let y = group.frame.minY
        group.tap()
        waitUntil("过程展开") { group.value as? String == "已展开" }
        XCTAssertTrue(group.isHittable, "展开过程不能把刚点击的入口卷出屏幕")
        XCTAssertEqual(group.frame.minY, y, accuracy: 40)
        try screenshot("process-expanded-position")
    }

    func testVoiceCallIsRemovedAndDictationRemains() throws {
        XCTAssertTrue(app.buttons["composer.mic"].exists)
        tap("chat.menu")
        XCTAssertTrue(app.buttons["list.me"].waitForExistence(timeout: 5))
        app.buttons["list.me"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        for _ in 0..<5 {
            XCTAssertFalse(app.buttons["settings.call"].exists)
            XCTAssertFalse(app.buttons["开始语音通话"].exists)
            app.swipeUp()
        }
        try screenshot("v709-settings-without-voice-call")
    }

    func testScrollReadingHistoryIsNotPulledByReplyGrowth() throws {
        try openScrollHistory()
        typeScrollMessage()
        let beforeSend = metric("ag")
        app.buttons["composer.send"].tap()
        waitUntil("合成回合启动") {
            self.metric("busy") == 1 && self.metric("ag") > beforeSend && self.app.keyboards.count == 0
        }
        app.scrollViews["chat.messages"].swipeDown(velocity: .slow)
        waitUntil("翻历史后停止滚动") {
            self.metric("y") > 150 && self.metric("hold") == 0 && self.metric("latest") == 1
        }
        try screenshot("scroll-v709-reading-history")
        for _ in 0..<6 {
            let previous = metric("ag")
            _ = try control("scroll/grow")
            waitUntil("阅读历史时收到新正文") { self.metric("ag") > previous }
            XCTAssertGreaterThan(metric("y"), 150, "新回复把阅读位置拽回底部")
            XCTAssertEqual(metric("bot"), 0)
            XCTAssertEqual(metric("latest"), 1)
        }
        _ = try control("scroll/complete")
        try screenshot("scroll-v709-history-after-reply")
    }

    private func openScrollHistory() throws {
        app.terminate()
        let fixture = try control("scroll/history")
        let id = try XCTUnwrap(fixture["threadId"] as? String)
        app.launchEnvironment["CODEX_PHONE_OPEN"] = id
        app.launchArguments = ["-draft.v2.ws://127.0.0.1:18182/ws." + id, ""]
        app.launch()
        XCTAssertTrue(app.buttons["chat.menu"].waitForExistence(timeout: 15))
        waitUntil("长历史打开后贴底") {
            self.metric("ch") > self.metric("vh") * 3 && self.metric("y") <= 40
                && self.metric("bot") == 1
        }
    }

    private func typeScrollMessage() {
        let field = app.textViews["composer.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("检查发送后的滚动位置\n第二行继续输入\n第三行让输入框增高")
        waitUntil("发送按钮可用") { self.app.buttons["composer.send"].isEnabled }
    }

    private func metric(_ key: String) -> Int {
        let state = app.descendants(matching: .any)["chatState"].firstMatch.value as? String ?? ""
        let prefix = key + "="
        return state.split(separator: " ").first(where: { $0.hasPrefix(prefix) })
            .flatMap { Int($0.dropFirst(prefix.count)) } ?? -1
    }

    private func waitUntil(_ message: String, _ condition: @escaping () -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed, message)
    }

    private func assertPinnedForTwoSeconds() {
        let deadline = Date().addingTimeInterval(2)
        var samples = 0
        while Date() < deadline {
            XCTAssertLessThanOrEqual(metric("y"), 40, "键盘收起后延迟跳离最新消息")
            XCTAssertEqual(metric("bot"), 1)
            samples += 1
        }
        XCTAssertGreaterThan(samples, 2, "没有读到持续滚动样本")
    }

    private func control(_ path: String, method: String = "POST") throws -> [String: Any] {
        let done = expectation(description: path)
        var data: Data?
        var error: Error?
        var status: Int?
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        URLSession.shared.dataTask(with: request) { body, response, failure in
            data = body; error = failure
            status = (response as? HTTPURLResponse)?.statusCode
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let error { throw error }
        XCTAssertEqual(status, 200, path)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func disappeared(_ element: XCUIElement) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: 8)
    }

    private func tap(_ id: String) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), id)
        reveal(button)
        button.tap()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable, element.identifier)
    }

    private func screenshot(_ name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/codexpocket-award-states")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shot = XCUIScreen.main.screenshot()
        try shot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func response(_ id: String) throws -> [String: Any] {
        for _ in 0..<20 {
            let records = try control("responses", method: "GET")["responses"] as? [[String: Any]] ?? []
            let matches = records.filter { $0["id"] as? String == id }
            if let reply = matches.first {
                XCTAssertEqual(matches.count, 1, "同一请求只能回答一次")
                XCTAssertNil(reply["method"])
                XCTAssertNil(reply["error"])
                return try XCTUnwrap(reply["result"] as? [String: Any])
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTFail("未收到请求 \(id) 的回答")
        return [:]
    }
}

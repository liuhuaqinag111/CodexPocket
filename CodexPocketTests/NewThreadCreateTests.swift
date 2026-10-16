import XCTest
@testable import CodexPocket

/// 「新会话有时候建不出来」。
///
/// 根因：手机网络十几秒抖一次（桥接日志里 465 次 code=1006），
/// 用户正好点在那个窗口里时，`WebSocketTransport.send` 发现 socket 没就绪就
/// 立刻回错，请求压根没上路。旧代码对这种错误不重试，
/// 直接 `done(nil)` —— 表现就是"点了什么都没发生"。
/// 而且旧代码"任何错误都丢模型"，网络一抖新会话就悄悄用了默认模型。
@MainActor
final class NewThreadCreateTests: XCTestCase {
    func testOpeningEmptyThreadHasNoBannerAndCanLoadItsFirstReply() async {
        let wire = RecordingTransport()
        wire.result = .failure(WebSocketTransport.RPCError(message:
            "thread new is not materialized yet; thread/turns/list is unavailable before first user message", code: -32600))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = PreferencesModel(), oldHost = PreferencesModel().host
        settings.host = ""
        defer { settings.host = oldHost }
        let list = ThreadListModel(repository: ThreadRepository(transport: RecordingTransport()), settings: settings)
        let chat = ConversationModel(repository: ConversationRepository(transport: wire,
            cache: SnapshotCache(directory: directory, namespace: "empty-thread")), settings: settings, list: list)
        chat.open(id: "new")
        defer { chat.close() }
        for _ in 0..<50 where chat.loading { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(chat.loading)
        XCTAssertNil(chat.banner)
        XCTAssertTrue(chat.items.isEmpty)
        wire.result = .success(["turn": ["id": "first", "status": "inProgress"]] as JSONDict)
        chat.send("hello", localID: "first-user")
        for _ in 0..<50 where !chat.acceptedSubmissionIDs.contains("first-user") {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(chat.acceptedSubmissionIDs.contains("first-user"))
        XCTAssertEqual(chat.items.filter { $0.id == "first-user" }.count, 1)
        wire.result = .success(["data": [["id": "first", "status": "completed", "items": [
            ["id": "answer", "type": "agentMessage", "text": "first reply"]]]]] as JSONDict)
        chat.reload()
        for _ in 0..<50 where !chat.items.contains(.agent(id: "answer", text: "first reply")) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(chat.items.contains(.agent(id: "answer", text: "first reply")))
        wire.result = .failure(RepositoryError(message: "connection reset"))
        chat.reload()
        for _ in 0..<50 where chat.banner == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(chat.banner, "connection reset")
    }

    func testCreateCallbackCannotSendFirstMessageAfterChangingServer() async {
        let wire = RecordingTransport(); wire.deferResponse = true
        let store = AppCoordinator(transport: wire)
        var sentDraft = false
        store.list.onFirstMessage = { _, _ in sentDraft = true }
        store.list.create(cwd: "/old", model: "chosen", effort: "high", first: "draft") { _ in
            store.prepareConnection(namespace: "other-server")
        }
        wire.pending?(.success(["thread": ["id": "old-created"]] as JSONDict))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(sentDraft)
        store.chat.close()
    }

    func testQueuedCreateRetryStopsWhenServerChanges() async throws {
        let wire = RecordingTransport()
        wire.result = .failure(RepositoryError(message: "还没连上电脑，稍后再试"))
        let store = AppCoordinator(transport: wire)
        var finished = false
        store.list.create(cwd: "/old", model: "chosen", effort: "high", first: "draft") { _ in
            finished = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.list.banner, "正在建新会话…")
        store.prepareConnection(namespace: "changed-server")
        try await Task.sleep(nanoseconds: 1_700_000_000)
        XCTAssertEqual(wire.calls.filter { $0.0 == "thread/start" }.count, 1)
        XCTAssertTrue(finished)
        store.chat.close()
    }

    func testLateCreateCannotImportThreadOrSendDraftToAnotherServer() async {
        let wire = RecordingTransport(); wire.deferResponse = true
        let store = AppCoordinator(transport: wire)
        var finished = false
        var created: String?
        var sentDraft = false
        store.list.onFirstMessage = { _, _ in sentDraft = true }
        store.list.create(cwd: "/old", model: "old-model", effort: "high", first: "private draft") {
            finished = true; created = $0
        }
        let reply = wire.pending
        store.prepareConnection(namespace: "new-server")
        let count = wire.calls.count
        reply?(.success(["thread": ["id": "old-created", "cwd": "/old"]] as JSONDict))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(finished)
        XCTAssertNil(created)
        XCTAssertFalse(sentDraft)
        XCTAssertTrue(store.list.threads.isEmpty)
        XCTAssertTrue(store.list.pendingNew.isEmpty)
        XCTAssertEqual(wire.calls.count, count)
        store.chat.close()
    }

    func testRejectedCreateDoesNotDropSelectedModel() async {
        let transport = RecordingTransport()
        transport.result = .failure(RepositoryError(message: "Invalid request: unknown model"))
        let list = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
        var completed = false
        list.create(cwd: "/tmp", model: "chosen-model", effort: "max", first: nil) { _ in
            completed = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(completed)
        XCTAssertEqual(transport.calls.filter { $0.0 == "thread/start" }.count, 1)
        XCTAssertEqual(transport.calls.first?.1.str("model"), "chosen-model")
        XCTAssertNotNil(list.banner)
    }

    func testExplicitNewThreadPreservesExistingDraft() {
        let store = AppCoordinator()
        store.list.currentID = "synthetic-old"
        store.composer.text = "do not execute this draft"
        store.composer.newThread()
        XCTAssertEqual(store.composer.text, "do not execute this draft")
        XCTAssertTrue(store.composer.creatingThread)
    }

    func testCurrentProjectOpensOnlyWhenRequestedAndCanBeCollapsed() {
        let store = AppCoordinator()
        let thread = Thread(json: ["id": "current", "cwd": "/work/project"])!
        store.list.__testSeed(threads: [thread], archived: [])
        store.list.currentID = thread.id
        store.settings.openProjects = []
        store.settings.closedProjects = []
        let group = ThreadListModel.Group(id: "project", title: "项目", path: "/work",
                                      threads: [thread], isProject: true)

        XCTAssertFalse(store.list.isOpen(group))
        store.list.toggle(group)
        XCTAssertTrue(store.list.isOpen(group))
        store.list.toggle(group)
        XCTAssertFalse(store.list.isOpen(group))
    }

    /// 只有 socket 未就绪能确定没发出去；断线/超时可能已经建成。
    func testOnlyDefinitelyUnsentCreateIsRetryable() {
        XCTAssertTrue(ThreadListModel.isOffline("还没连上电脑，稍后再试"))
        XCTAssertFalse(ThreadListModel.isOffline("连接已断开"))
        XCTAssertFalse(ThreadListModel.isOffline("请求超时：thread/start"))
        XCTAssertFalse(ThreadListModel.isOffline("连接中断"))
    }

    /// 服务端拒绝不自动重建，也不能悄悄改用默认模型。
    func testServerRejectionsAreNotOffline() {
        XCTAssertFalse(ThreadListModel.isOffline("Invalid request: unknown model"))
        XCTAssertFalse(ThreadListModel.isOffline("server is draining"))
        XCTAssertFalse(ThreadListModel.isOffline("thread not found"))
    }

    /// 断线时**不能**直接放弃：要挂个提示、等连接起来再发。
    @MainActor
    func testOfflineDoesNotGiveUpImmediately() async {
        let store = AppCoordinator()          // 没连接，send 会立刻失败
        var finished = false
        store.list.create(cwd: "~", model: "global:deepseek-v4.1-flash",
                          effort: "max", first: "你好") { _ in finished = true }
        XCTAssertFalse(finished, "断线时直接收摊了 —— 用户点新会话会没有任何反应")
        // 回包是异步落到 MainActor 上的，等它跑完再断言。
        let exp = expectation(description: "等提示出现")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 3)
        XCTAssertEqual(store.list.banner, "正在建新会话…", "没有给出任何提示")
    }

    /// 提示要真的显示出来。以前 RootView 只读 `store.banner`，
    /// chat / list 里的报错从来没露过面。
    @MainActor
    func testBannerFromAnyStoreIsVisible() {
        let store = AppCoordinator()
        store.chat.banner = "没发出去：连接中断"
        XCTAssertEqual(store.activeBanner, "没发出去：连接中断")
        store.clearBanner()
        XCTAssertNil(store.activeBanner)
    }
}

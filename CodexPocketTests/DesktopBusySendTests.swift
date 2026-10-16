import XCTest
@testable import CodexPocket

/// **电脑端在这个会话里跑着的时候，手机上按发送会怎样。**
///
/// 用户报的：「电脑并没有给一个会话发消息，但是手机显示等电脑执行完发送」。
/// 这里用假的 repository 把四种状态摆出来，量 `send` 到底走了哪条路。
@MainActor
final class DesktopBusySendTests: XCTestCase {

    /// 记录每次调用的假 repository。只回成功，不需要真网络。
    final class Recorder: ConversationRepositoryProtocol {
        let cache = SnapshotCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("desktop-busy-tests"), namespace: "unit-tests")
        var isReady = true
        var calls: [String] = []
        var onCall: ((String, JSONDict) -> Result<Any, Error>)?
        func reconnect() {}
        func cachedItems(_ id: String) -> [Item] { [] }
        func refreshSnapshot(_ id: String, limit: Int, done: @escaping (Result<[Item], Error>) -> Void) {
            done(.success([]))
        }
        func perform(_ operation: ConversationOperation, done: RepositoryResult?) {
            let (method, params) = ConversationRepository.request(operation)
            calls.append(method)
            let r = onCall?(method, params) ?? .success([:])
            done?(r)
        }
    }

    /// 假输入源：ComposerModel 的文件搜索。
    final class InputStub: InputRepositoryProtocol {
        var isReady = true
        func reconnect() {}
        func searchFiles(query: String, roots: [String], done: @escaping RepositoryResult) { done(.success([])) }
    }

    private func makeComposer(_ rec: Recorder) -> (ComposerModel, ConversationModel) {
        let list = ThreadListModel(
            repository: ThreadRepository(transport: WebSocketTransport()),
            settings: PreferencesModel())
        let chat = ConversationModel(repository: rec, settings: PreferencesModel(), list: list)
        let composer = ComposerModel(repository: InputStub(), list: list, chat: chat,
                                     settings: PreferencesModel())
        return (composer, chat)
    }

    private func makeChat(_ rec: Recorder) -> ConversationModel {
        makeComposer(rec).1
    }

    /// 电脑端在跑、本地又不知道回合 id → 先问服务端；问不到才排队。
    /// 无论如何不能走 `turn/start`（那个会另起一个回合）。
    func testDesktopRunningQueuesInsteadOfStart() {
        let rec = Recorder()
        let chat = makeChat(rec)
        chat.list.currentID = "t-desktop"
        chat.busy = true
        chat.localTurn = false
        chat.serverTurnId = nil
        chat.send("第二句")
        XCTAssertTrue(rec.calls.contains("thread/queue/add"),
                      "电脑端在跑时没排队，实际调用：\(rec.calls)")
        XCTAssertFalse(rec.calls.contains("turn/start"),
                       "电脑端在跑时直接 turn/start 会撞写者锁")
    }

    /// 自己刚发的回合在跑（localTurn=true）→ 走 `turn/start` 或 steer，
    /// 不能因为 busy 就排队（排队在没人跑的时候不会被执行）。
    func testOwnRunningTurnDoesNotQueue() {
        let rec = Recorder()
        let (composer, chat) = makeComposer(rec)
        chat.list.currentID = "t-mine"
        chat.busy = true
        chat.localTurn = true
        chat.serverTurnId = "turn-mine"
        composer.text = "再来一句"
        composer.submit()
        XCTAssertFalse(rec.calls.contains("thread/queue/add"),
                       "自己跑的回合不该排队：\(rec.calls)")
        XCTAssertTrue(rec.calls.contains("turn/steer") || rec.calls.contains("turn/start"),
                      "自己跑的回合该插话或新开回合：\(rec.calls)")
    }

    /// 第一句发出去、回合 id 还没回来（serverTurnId=nil）时再点发送：
    /// 走**插话**（`steer()` 会先问一次 `thread/turns/list` 拿 id），
    /// 不能 turn/start，也不是排队。
    ///
    /// 老断言是 "该排队" —— 那正是用户报的「切回来显示排队」。
    /// 2026-10-14 真桥接实测：没有 id 时先问一次就能插进去。
    func testUnknownTurnIdWhileBusySteers() {
        let rec = Recorder()
        let (composer, chat) = makeComposer(rec)
        chat.list.currentID = "t-unknown"
        chat.busy = true
        chat.localTurn = true
        chat.serverTurnId = nil
        composer.text = "第二句"
        composer.submit()
        XCTAssertTrue(rec.calls.contains("thread/turns/list"),
                      "回合 id 未知时该先问服务端：\(rec.calls)")
        XCTAssertFalse(rec.calls.contains("turn/start"),
                       "回合 id 未知时 turn/start 会多出一条一样的消息")
        // 问不到活动回合才允许落回队列 —— 那是真没人在跑。
        XCTAssertTrue(rec.calls.firstIndex(of: "thread/turns/list")!
                      < (rec.calls.firstIndex(of: "thread/queue/add") ?? .max),
                      "没问服务端就直接排队了：\(rec.calls)")
    }

    /// 空闲时点发送 = 普通发送（走 turn/start，不排队）。
    func testIdleSendStartsTurn() {
        let rec = Recorder()
        let (composer, chat) = makeComposer(rec)
        chat.list.currentID = "t-idle"
        composer.text = "第一句"
        composer.submit()
        XCTAssertTrue(rec.calls.contains("thread/start") || rec.calls.contains("turn/start")
                      || rec.calls.contains("thread/resume"),
                      "空闲发送没走发送路径：\(rec.calls)")
        XCTAssertFalse(rec.calls.contains("thread/queue/add"), "空闲发送不该排队")
    }

    /// 插话必须带上服务端的回合 id。
    ///
    /// 本地没有 id（切会话回来 / app 重启）时**先问一次**服务端再插 ——
    /// 不能直接降级排队，那是用户报的「一切出去插话就变成排队了」。
    /// 但**也不能**退回 `turn/start`：那会另起一个回合、消息重复一遍。
    func testSteerWithoutTurnIdAsksServerBeforeQueueing() async {
        let rec = Recorder()
        rec.onCall = { method, _ in
            guard method == "thread/turns/list" else { return .success([:]) }
            return .success(["data": [[
                "id": "turn-live", "status": "inProgress",
                "items": [["id": "u", "type": "userMessage", "clientId": "local-old"]]
            ]]] as JSONDict)
        }
        let chat = makeChat(rec)
        chat.list.currentID = "t-steer"
        chat.steer("插一句")
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(rec.calls.contains("thread/turns/list"),
                      "没去问活动回合 id：\(rec.calls)")
        XCTAssertTrue(rec.calls.contains("turn/steer"),
                      "问到 id 之后没插话：\(rec.calls)")
        XCTAssertFalse(rec.calls.contains("thread/queue/add"),
                       "问到 id 了不该降级成排队：\(rec.calls)")
        XCTAssertFalse(rec.calls.contains("turn/start"),
                       "没有回合 id 时插话不能新开回合（会重复消息）")
    }

    /// 服务端也说没有活动回合 → 才退回共享队列。
    func testSteerWithoutTurnIdAndNoLiveTurnQueues() async {
        let rec = Recorder()
        let chat = makeChat(rec)
        chat.list.currentID = "t-steer"
        chat.steer("插一句")
        for _ in 0..<40 { await Task.yield() }
        XCTAssertTrue(rec.calls.contains("thread/queue/add"),
                      "问不到活动回合时该排队：\(rec.calls)")
        XCTAssertFalse(rec.calls.contains("turn/start"),
                       "不能新开回合（会重复消息）")
    }

    /// 电脑端占着这个会话 → **照样插话**。
    ///
    /// 老断言写的是"占着时 steer 必然失败（thread not found）"，2026-10-14
    /// 用真桥接 + 真服务端量过：占锁只挡 `thread/resume`，
    /// `turn/steer` 成功，插话进模型、改变了答复。
    /// 预先降级成排队就是用户报的「切回来还是排队」。
    func testDesktopLockedStillSteers() {
        let rec = Recorder()
        let chat = makeChat(rec)
        chat.list.currentID = "t-locked"
        chat.desktopLocked = true
        chat.busy = true
        chat.localTurn = false
        chat.serverTurnId = "turn-desktop"
        chat.steer("插一句")
        XCTAssertTrue(rec.calls.contains("turn/steer"),
                      "电脑端占着也该先试插话：\(rec.calls)")
        XCTAssertFalse(rec.calls.contains("thread/queue/add"),
                       "没试插话就降级成排队：\(rec.calls)")
    }

    /// 插话兜底判定**必须带 `itemsView: full`**。
    ///
    /// 默认 summary 里**永远没有**插话那条（实测：进行中 items=1，
    /// 跑完也只有第一句），判定恒为 false → 降级 `turn/start` 重发 →
    /// 服务端把同一句写进同一个回合第二遍 = 两条一样的消息。
    func testSteerFallbackAsksForFullItems() async {
        let rec = Recorder()
        let chat = makeChat(rec)
        chat.list.currentID = "t-fb"
        var views: [String] = []
        let requested = expectation(description: "full history requested after status")
        rec.onCall = { method, params in
            if method == "bridge/submission/status" { return .success(["state": "unknown"] as JSONDict) }
            if method == "thread/turns/list" {
                views.append(params.str("itemsView") ?? "(缺失)")
                requested.fulfill()
                return .success(["data": [["id": "turn-1", "items": []]]] as JSONDict)
            }
            return .success([:])
        }
        chat.fallbackAfterSteer(threadId: "t-fb", text: "插一句", images: [], localId: "local-fb")
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(Array(rec.calls.prefix(2)), ["bridge/submission/status", "thread/turns/list"])
        XCTAssertEqual(views, ["full"],
                       "兜底判定用了 summary，永远看不到插话那条")
        XCTAssertFalse(rec.calls.contains("turn/start"))
        XCTAssertEqual(chat.pendingSend?.id, "local-fb")
    }

    /// 回合还在跑 → 兜底**不能**降级 `turn/start`（会把同一句写进同一回合第二遍）。
    func testSteerFallbackDoesNotRestartWhileRunning() {
        let rec = Recorder()
        let chat = makeChat(rec)
        chat.list.currentID = "t-run"
        chat.busy = true
        chat.localTurn = true
        chat.serverTurnId = "turn-9"
        rec.onCall = { method, _ in
            if method == "thread/turns/list" { return .success(["data": []]) }
            return .success([:])
        }
        chat.fallbackAfterSteer(threadId: "t-run", text: "插一句", images: [], localId: "local-run")
        XCTAssertFalse(rec.calls.contains("turn/start"),
                       "回合在跑还降级 turn/start —— 服务端会多出一条一样的消息：\(rec.calls)")
    }

    /// 有回合 id 时插话走 `turn/steer`，并且**带上 expectedTurnId**。
    func testSteerCarriesExpectedTurnId() {
        let rec = Recorder()
        let chat = makeChat(rec)
        chat.list.currentID = "t-steer2"
        chat.serverTurnId = "turn-abc"
        var seen: JSONDict = [:]
        rec.onCall = { method, params in
            if method == "turn/steer" { seen = params }
            return .success(["turnId": "turn-abc"])
        }
        chat.steer("插一句")
        XCTAssertEqual(seen.str("expectedTurnId"), "turn-abc",
                       "插话没带 expectedTurnId，服务端会拒（实测）")
        XCTAssertEqual(seen.str("clientUserMessageId")?.hasPrefix("local-"), true)
    }

    /// **刚 `thread/start` 出来的会话，第一句话必须发得出去。**
    ///
    /// 服务端在会话落盘之前，`thread/resume` 会回
    /// "no rollout found for thread id ..."（实测：建完 1 秒内必现）。
    /// 这条错误**不代表发不出去** —— `turn/start` 自己会创建 rollout。
    /// 以前这里直接标红，用户看到的就是「新会话刚建好，第一句话发不出去」，
    /// 得再点一次才成功（第二次 rollout 已经落盘了）。
    func testFreshThreadResumeNoRolloutStillSends() {
        let rec = Recorder()
        let chat = makeChat(rec)
        chat.list.currentID = "t-fresh"
        var resumeCalls = 0
        rec.onCall = { method, _ in
            if method == "thread/resume" {
                resumeCalls += 1
                // 第一次报 no rollout，重试那次放行 —— 跟现场一致。
                if resumeCalls == 1 {
                    return .failure(RepositoryError(message:
                        "no rollout found for thread id 01a12f9e-ad14-7cd1-8322"))
                }
            }
            return .success(["turn": ["id": "turn-fresh"]])
        }
        chat.startTurn(threadId: "t-fresh", text: "第一句", images: [],
                       localId: "local-fresh", configurationReady: true)
        // 等那条 1.2 秒的重试定时器真的跑完。
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !rec.calls.contains("turn/start") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(rec.calls.contains("turn/start"),
                      "新会话第一句话没发出去，调用序列=\(rec.calls)")
        // accept() 会把发送态清掉；还留着就是 failed/queued。
        XCTAssertNil(chat.sendStates["local-fresh"],
                     "第一句话被标成没发出去：\(String(describing: chat.sendStates["local-fresh"]))")
        XCTAssertFalse(chat.failed.contains("local-fresh"))
    }
}

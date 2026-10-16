import XCTest
import AVFoundation
@testable import CodexPocket

/// 耗电：常驻定时器的频率 + 对账只拉第一页。
///
/// 实测（2026-10-06，模拟器，什么都不做）：
///   列表页 60 秒 43 个请求（thread/list 39）
///   会话页 60 秒 35 个请求（thread/turns/list 29）
/// 用户报「太耗电了」。
final class PowerTests: XCTestCase {
    @MainActor
    func testBackgroundRunningNotificationCannotRestartPolling() {
        let store = AppCoordinator()
        let keepAlive = store.settings.keepAlive
        store.settings.keepAlive = false
        defer {
            store.disconnect()
            store.settings.keepAlive = keepAlive
        }
        store.list.currentID = "background-thread"
        store.enterBackground()
        store.chat.apply("thread/status/changed", ["threadId": "background-thread",
            "status": ["type": "active"]])
        XCTAssertNil(store.chat.remoteTimer)
        let tick = store.chat.remoteTick
        store.chat.pollRemote("background-thread")
        XCTAssertEqual(store.chat.remoteTick, tick, "Background polling sent a history request")
        store.enterForeground()
        XCTAssertNotNil(store.chat.remoteTimer)
    }

    func testKeepAliveRestoresPlaybackAfterDictation() throws {
        let session = AVAudioSession.sharedInstance()
        let category = session.category, mode = session.mode, options = session.categoryOptions
        defer { try? session.setCategory(category, mode: mode, options: options) }
        let keeper = BackgroundKeeper.shared
        keeper.prepare()
        try session.setCategory(.record, mode: .measurement)
        keeper.prepare()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(session.mode, .default)
    }

    @MainActor
    func testColdNotificationSurvivesStoreAndListInitialization() {
        let previous = AppDelegate.store
        defer { AppDelegate.store = previous }
        AppDelegate.store = nil
        AppDelegate.requestOpenThread("cold-start-target")
        XCTAssertEqual(AppDelegate.pendingThreadID, "cold-start-target")
        let store = AppCoordinator()
        AppDelegate.store = store
        XCTAssertNil(AppDelegate.pendingThreadID)
        XCTAssertEqual(store.pendingOpen, "cold-start-target")
        XCTAssertNil(store.list.currentID)
        store.requestOpenThread("newer-target")
        XCTAssertEqual(store.pendingOpen, "newer-target")
        store.requestOpenThread("")
        XCTAssertEqual(store.pendingOpen, "newer-target")
    }

    @MainActor
    func testForegroundRestoresChatPolling() {
        let store = AppCoordinator()
        let keepAlive = store.settings.keepAlive
        store.settings.keepAlive = false
        defer {
            store.disconnect()
            store.settings.keepAlive = keepAlive
        }
        store.list.currentID = "lifecycle-test-thread"
        store.chat.startRemoteWatch("lifecycle-test-thread")
        store.enterBackground()
        XCTAssertNil(store.chat.remoteTimer)
        store.enterForeground()
        XCTAssertNotNil(store.chat.remoteTimer)
    }

    func testAudioInterruptionResumesOnlyWhenAllowed() {
        let typeKey = AVAudioSessionInterruptionTypeKey
        let optionKey = AVAudioSessionInterruptionOptionKey
        XCTAssertFalse(BackgroundKeeper.shouldResumeAfterInterruption([typeKey: UInt(1)]))
        XCTAssertFalse(BackgroundKeeper.shouldResumeAfterInterruption([typeKey: UInt(0)]))
        XCTAssertTrue(BackgroundKeeper.shouldResumeAfterInterruption([
            typeKey: UInt(0), optionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
        ]))
    }

    private func th(_ id: String, _ title: String, _ ts: Double) -> CodexPocket.Thread {
        CodexPocket.Thread(json: ["id": id, "name": title, "cwd": "/tmp", "updatedAt": ts])!
    }

    /// 对账间隔从 8 秒放到 20 秒。
    func testReconcileIntervalSlowed() {
        XCTAssertGreaterThanOrEqual(reconcileInterval, 20,
                                    "对账一次 2 个请求，8 秒一轮就是 15 个/分钟")
    }

    /// 会话轮询要分快慢两档。
    @MainActor
    func testRemotePollIsAdaptive() {
        XCTAssertGreaterThanOrEqual(ConversationModel.pollIdle, 15,
                                    "空闲档太密 —— 没回合在跑时不该这么频繁")
        XCTAssertLessThanOrEqual(ConversationModel.pollBusy, 3,
                                 "在跑的时候要跟得上流式内容")
        XCTAssertGreaterThan(ConversationModel.pollIdle, ConversationModel.pollBusy,
                             "空闲档必须比忙档慢，否则分档没意义")
    }

    /// 对账只拉第一页 —— 全量翻页是 `load()` 的事。
    ///
    /// 第一页只有最新 100 条，直接替换会把更老的会话从列表里抹掉，
    /// 所以必须是**合并**。
    @MainActor
    func testMergeFirstPageKeepsOlderThreads() {
        let fresh = [th("n1", "新", 300), th("n2", "也新", 200)]
        let existing = [th("n2", "也新", 200), th("old", "老", 100)]
        let out = ThreadListModel.mergeFirstPage(fresh: fresh, existing: existing)
        XCTAssertEqual(out.map { $0.id }, ["n1", "n2", "old"],
                       "第一页里没有的老会话被抹掉了 —— 列表会凭空少一大截")
    }

    /// 第一页里的条目要更新成服务端那一份（比如改了名字）。
    @MainActor
    func testMergeFirstPagePrefersFresh() {
        let fresh = [th("a", "新名字", 300)]
        let existing = [th("a", "旧名字", 100)]
        let out = ThreadListModel.mergeFirstPage(fresh: fresh, existing: existing)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].title, "新名字", "用的是旧的那一份")
    }

    /// **切后台必须把所有轮询停掉。**
    ///
    /// 以前两个定时器只跟视图的 onAppear / onDisappear 绑着，切后台不停 ——
    /// 保活开着时进程还活着、RunLoop 还在跑，于是整夜在后台每 2.5 秒拉一次
    /// turns、每 8 秒拉一次列表。用户报的「太耗电了」主要是这一段。
    @MainActor
    func testBackgroundStopsAllPolling() {
        let store = AppCoordinator()
        store.list.startReconcile()
        XCTAssertTrue(store.list.isReconciling, "列表对账没起来，测不了")

        store.enterBackground()

        XCTAssertFalse(store.list.isReconciling, "切后台了列表对账还在跑")
        XCTAssertNil(store.chat.remoteTimer, "切后台了会话轮询还在跑")
    }

    /// 回前台要把对账接回来（但只在列表页本来就开着的时候）。
    @MainActor
    func testForegroundResumesReconcileOnlyIfWanted() {
        let store = AppCoordinator()
        store.enterBackground()
        store.enterForeground()
        XCTAssertFalse(store.list.isReconciling,
                       "列表页根本没开过，回前台却把对账跑起来了 —— 白烧请求")

        store.list.startReconcile()
        store.enterBackground()
        store.enterForeground()
        XCTAssertTrue(store.list.isReconciling,
                      "列表页开着切了一次后台，回来就不刷新了")
    }

    /// 同一个回合只通知一次，跨会话也不重复。
    @MainActor
    func testNotifierDeduplicatesTurns() {
        XCTAssertFalse(Notifier.alreadyFired("turn-x"))
        Notifier.markFired("turn-x")
        XCTAssertTrue(Notifier.alreadyFired("turn-x"),
                      "换会话/重进会话后同一个回合会再响一次 —— 通知要振动亮屏，重复响很耗电")
    }
}

/// 「会话都加载不出来」那次故障的两道防线。
///
/// 根因不在 App：`supervise.sh` 里一段注释插进了 `\` 续行链中间，
/// 把后面的赋值连同启动命令一起注释掉了，桥接退回它自己的默认上游
/// 62112（早就没有的端口）。app-server 在 62115 跑得好好的，手机也
/// 显示"已连接"，但一条数据都拿不到。
final class LoadFailureTests: XCTestCase {

    /// 桥接要能把"上游端口对不对"说清楚。
    ///
    /// `/healthz` 永远回 ok，看不出这种故障 —— 所以加了 `/status`。
    func testBridgeExposesUpstreamPort() throws {
        let bridge = TestSource.path("bridge/bridge.mjs")
        let src = (try? String(contentsOfFile: bridge, encoding: .utf8)) ?? ""
        try XCTSkipIf(src.isEmpty, "读不到 bridge.mjs")
        XCTAssertTrue(src.contains("'/status'"),
                      "桥接没有 /status —— 上游指错端口时无从查起")
        XCTAssertTrue(src.contains("upstreamPort"),
                      "/status 里没报上游端口")
    }

    /// 看门狗要主动查桥接的上游端口。
    func testWatchdogChecksUpstreamPort() throws {
        let sup = TestSource.path("bridge/supervise.sh")
        let src = (try? String(contentsOfFile: sup, encoding: .utf8)) ?? ""
        try XCTSkipIf(src.isEmpty, "读不到 supervise.sh")
        XCTAssertTrue(src.contains("upstreamPort"),
                      "看门狗不查上游端口 —— 指错了永远没人纠正")
    }

    /// **续行链中间不许夹注释。**
    ///
    /// `\` + 换行会把两行接成一行，注释插在链条中间会把后面所有赋值
    /// 连同命令一起注释掉。这个坑让整台手机断了一上午。
    func testNoCommentInsideLineContinuation() throws {
        let sup = TestSource.path("bridge/supervise.sh")
        let lines = ((try? String(contentsOfFile: sup, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        try XCTSkipIf(lines.isEmpty, "读不到 supervise.sh")
        var bad: [Int] = []
        for (i, l) in lines.enumerated() where l.hasSuffix("\\") {
            let next = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
            if next.hasPrefix("#") { bad.append(i + 1) }
        }
        XCTAssertTrue(bad.isEmpty,
                      "这些行后面续行接着注释，会把整条命令注释掉：\(bad)")
    }

    /// 「连上了但拉回来是空的」必须跟「还没建过会话」区分开。
    @MainActor
    func testEmptyListAfterFetchIsDistinguishable() {
        let store = AppCoordinator()
        XCTAssertFalse(store.list.fetchedOnce,
                       "还没拉过就当成'拉过了'——空列表会被误报成故障")
    }
}

import XCTest
@testable import CodexPocket

private final class ModelSyncTransport: RPCTransport {
    var calls: [(String, JSONDict)] = []
    var pendingRead: RepositoryResult?
    var pendingList: RepositoryResult?
    var deferList = false
    var deferRead = false
    var deferSettings = false
    var completedTurn = false
    var deferProviders = false
    var pendingProviders: [RepositoryResult] = []
    var providerResult: Result<Any, Error> = .failure(NSError(domain: "rpc", code: -32601))
    var legacyModels: [JSONDict] = []
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        calls.append((method, params))
        if method == "bridge/provider/models" {
            if deferProviders { if let done { pendingProviders.append(done) } }
            else { done?(providerResult) }
            return calls.count
        }
        if method == "thread/list", deferList { pendingList = done; return calls.count }
        if method == "thread/settings/update", deferSettings { return calls.count }
        if method == "thread/read", deferRead { pendingRead = done; return calls.count }
        if method == "thread/read" {
            done?(.success(["thread": ["id": params.str("threadId") ?? "",
                "model": "desktop-model", "reasoningEffort": "max"]] as JSONDict))
        } else if method == "model/list" {
            done?(.success(["data": legacyModels] as JSONDict))
        } else if method == "config/read" {
            done?(.success(["config": ["model": "desktop-global", "model_reasoning_effort": "high"]] as JSONDict))
        } else if method == "thread/turns/list", completedTurn {
            done?(.success(["data": [["id": "old-turn", "status": "completed", "items": []]]] as JSONDict))
        } else { done?(.success(["data": []] as JSONDict)) }
        return calls.count
    }
}

/// 用户报的："为什么电脑端和手机显示的模型不一样？"
///
/// 根因（实测）：
///   1. `model/list` 是 app-server **启动时**读一次
///      `~/.codex/cc-switch-model-catalog.json` 缓存在内存里的，
///      文件变了不重读 —— 手机端一直报旧模型。
///      实测：目录里是 `global:deepseek-v4.1-flash`，
///      手机却报 `cn:deepseek-v4.1-flash`；杀掉 app-server 重拉立刻变回来。
///   2. 会话里存的模型可能**不在**目录里（切过供应商之后），
///      以前这种情况界面显示"默认模型"，看着就像两边不一致。
///
/// 本测试锁住第 2 条：不在目录里也必须**照实**显示服务端的原值。
@MainActor
final class ModelLabelTests: XCTestCase {

    private func providerCatalog(_ fingerprint: String, models: [String]) -> JSONDict {
        ["available": true,
         "provider": ["id": fingerprint, "name": fingerprint, "fingerprint": fingerprint, "model": "default"],
         "models": models.map { ["id": $0, "name": "Name " + $0, "detail": "Detail " + $0] }]
    }

    func testProviderCatalogShowsEveryModelAndKeepsHistoricalModel() {
        let s = makeStore()
        s.threads = [Thread(json: ["id": "old", "model": "previous-model"])!]
        s.currentID = "old"
        s.settings.defaultModel = "my-default"
        defer { s.settings.defaultModel = "" }
        let ids = (0..<125).map { "model-" + String($0) }
        s.applyProviderCatalog(providerCatalog("group-a", models: ids), sequence: 0)
        XCTAssertEqual(s.modelRows(current: s.resolvedModel).map(\.id), ids)
        XCTAssertEqual(s.models[1].name, "Name model-1")
        XCTAssertEqual(s.models[1].detail, "Detail model-1")
        XCTAssertEqual(s.resolvedModel, "previous-model")
        XCTAssertEqual(s.modelLabel(s.resolvedModel), "previous-model")
        XCTAssertEqual(s.settings.defaultModel, "my-default")
    }

    func testProviderSwitchReplacesCatalogAndRejectsOldReply() {
        let s = makeStore()
        s.applyProviderCatalog(providerCatalog("group-a", models: ["old"]), sequence: 0)
        s.modelReadSeq = 1
        s.applyProviderCatalog(providerCatalog("group-b", models: ["new", "second"]), sequence: 1)
        s.applyProviderCatalog(providerCatalog("group-a", models: ["old"]), sequence: 0)
        XCTAssertEqual(s.models.map(\.id), ["new", "second"])
        XCTAssertEqual(s.modelProviderFingerprint, "group-b")
    }

    func testProviderErrorClearsOldCatalogAndCanRecover() {
        let s = makeStore()
        s.applyProviderCatalog(providerCatalog("group-a", models: ["old"]), sequence: 0)
        var failed = providerCatalog("group-b", models: [])
        failed["error"] = "provider unavailable"
        s.applyProviderCatalog(failed, sequence: 0)
        XCTAssertTrue(s.models.isEmpty)
        XCTAssertNotNil(s.modelCatalogError)
        s.applyProviderCatalog(providerCatalog("group-b", models: ["new"]), sequence: 0)
        XCTAssertEqual(s.models.map(\.id), ["new"])
        XCTAssertNil(s.modelCatalogError)
    }

    func testModelRefreshUsesProviderCatalogAndThrottlesPolling() async {
        let transport = ModelSyncTransport()
        transport.providerResult = .success(providerCatalog("current", models: ["one", "two"]))
        let s = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
        s.refreshConfiguration()
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(s.models.map(\.id), ["one", "two"])
        s.refreshConfiguration(force: true)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(transport.calls.filter { $0.0 == "bridge/provider/models" }.count, 1)
        XCTAssertFalse(transport.calls.contains { $0.0 == "model/list" || $0.0 == "thread/settings/update" })
    }

    func testOlderBridgeAndMissingCCSwitchFallBackToModelList() async {
        for result: Result<Any, Error> in [
            .failure(NSError(domain: "rpc", code: -32601)),
            .success(["available": false, "models": []] as JSONDict)
        ] {
            let transport = ModelSyncTransport()
            transport.providerResult = result
            transport.legacyModels = [["id": "legacy"]]
            let s = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
            s.loadModels()
            for _ in 0..<12 { await Task.yield() }
            XCTAssertEqual(transport.calls.filter { $0.0 == "model/list" }.count, 1)
            XCTAssertEqual(s.models.map(\.id), ["legacy"])
            XCTAssertNil(s.modelCatalogError)
        }
    }

    func testLateProviderRequestCannotRestoreOldGroup() async {
        let transport = ModelSyncTransport()
        transport.deferProviders = true
        let s = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
        s.loadModels()
        s.loadModels()
        transport.pendingProviders[1](.success(providerCatalog("new", models: ["new-model"])))
        for _ in 0..<12 { await Task.yield() }
        transport.pendingProviders[0](.success(providerCatalog("old", models: ["old-model"])))
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(s.models.map(\.id), ["new-model"])
        XCTAssertEqual(s.modelProviderFingerprint, "new")
    }

    func testProviderRPCFailureClearsDirectoryAndAllowsImmediateRetry() async {
        let transport = ModelSyncTransport()
        let s = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
        s.applyProviderCatalog(providerCatalog("old", models: ["old"]), sequence: 0)
        transport.providerResult = .failure(RepositoryError(message: "timeout"))
        s.loadModels()
        for _ in 0..<12 { await Task.yield() }
        XCTAssertTrue(s.models.isEmpty)
        XCTAssertNotNil(s.modelCatalogError)
        transport.providerResult = .success(providerCatalog("new", models: ["one"]))
        s.loadModels(force: false)
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(s.models.map(\.id), ["one"])
        XCTAssertNil(s.modelCatalogError)
        XCTAssertFalse(transport.calls.contains { $0.0 == "model/list" })
    }

    /// `PreferencesModel` 直接读写 `UserDefaults.standard`，用例之间会串
    /// （前一个设了 `defaultModel`，后一个就变成"用户选过"了）。
    /// 每个用例先把这两个键清掉，保证隔离。
    private func makeStore() -> ThreadListModel {
        UserDefaults.standard.removeObject(forKey: "defaultModel")
        UserDefaults.standard.removeObject(forKey: "defaultEffort")
        let rpc = WebSocketTransport()
        let settings = PreferencesModel()
        return ThreadListModel(repository: ThreadRepository(transport: rpc), settings: settings)
    }

    func testEmptyFallsBackToDefaultLabel() {
        let s = makeStore()
        XCTAssertEqual(s.modelLabel(""), "默认模型")
    }

    func testOpenRefreshesDesktopThreadModelWithoutTakingWriterLock() async {
        let transport = ModelSyncTransport()
        let store = AppCoordinator(transport: transport)
        let thread = Thread(json: ["id": "model-sync", "model": "old-model"])!
        store.list.inject(threads: [thread])
        store.chat.open(thread)
        defer { store.chat.close() }
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(store.list.resolvedModel, "desktop-model")
        XCTAssertEqual(store.list.resolvedEffort, "max")
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/resume" })
        XCTAssertEqual(transport.calls.first { $0.0 == "thread/read" }?.1.bool("includeTurns"), false)
    }

    func testUnknownModelShowsRawValue() {
        let s = makeStore()
        // 目录是空的（模型还没拉回来）也不能撒谎。
        XCTAssertEqual(s.modelLabel("global:deepseek-v4.1-flash"),
                       "global:deepseek-v4.1-flash")
    }

    func testChatPollingRefreshesModelEvenWithoutAnyTurns() async {
        let transport = ModelSyncTransport()
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "model-sync", "model": "old-model"])!])
        store.list.currentID = "model-sync"
        store.chat.pollRemote("model-sync")
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(store.list.resolvedModel, "desktop-model")
        XCTAssertEqual(store.list.globalModel, "desktop-global")
        store.chat.pollRemote("model-sync")
        XCTAssertEqual(transport.calls.filter { $0.0 == "thread/read" }.count, 1)
    }

    func testSlowHistoryDoesNotBlockModelRefresh() async {
        let transport = ModelSyncTransport()
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "old-chat", "model": "old-model"])!])
        store.list.currentID = "old-chat"
        store.chat.remotePollInFlight = true
        store.chat.pollRemote("old-chat")
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(store.list.resolvedModel, "desktop-model")
        XCTAssertEqual(store.list.resolvedEffort, "max")
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/turns/list" })
    }

    func testListReconcileRefreshesDesktopGlobalModel() async {
        let transport = ModelSyncTransport()
        let s = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
        s.reconcile()
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(s.globalModel, "desktop-global")
    }

    func testSendingUsesFreshDesktopModelAndEffort() async {
        let transport = ModelSyncTransport()
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "model-sync", "model": "old-model"])!])
        store.list.currentID = "model-sync"
        store.chat.send("你好")
        for _ in 0..<20 { await Task.yield() }
        let params = transport.calls.first { $0.0 == "turn/start" }?.1
        XCTAssertEqual(params?.str("model"), "desktop-model")
        XCTAssertEqual(params?.str("effort"), "max")
        XCTAssertNil(params?["reasoningEffort"])
        store.chat.close()
    }

    func testLateReadCannotOverwriteNewPhoneChoice() async {
        let transport = ModelSyncTransport()
        transport.deferRead = true
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "model-sync", "model": "old-model"])!])
        store.list.currentID = "model-sync"
        store.chat.pollRemote("model-sync")
        store.list.setModel("phone-choice")
        transport.pendingRead?(.success(["thread": ["id": "model-sync", "model": "old-model"]] as JSONDict))
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(store.list.resolvedModel, "phone-choice")
    }

    func testLateReadCannotOverwriteDesktopSettingsEvent() async {
        let transport = ModelSyncTransport()
        transport.deferRead = true
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "sync", "model": "old"])!])
        store.list.currentID = "sync"
        store.list.refreshConfiguration(force: true)
        store.list.applyConfigurationEvent(["threadId": "sync",
            "threadSettings": ["model": "desktop-new", "effort": "max"]])
        transport.pendingRead?(.success(["thread": ["id": "sync",
            "model": "old", "reasoningEffort": "low"]] as JSONDict))
        for _ in 0..<12 { await Task.yield() }
        XCTAssertEqual(store.list.resolvedModel, "desktop-new")
        XCTAssertEqual(store.list.resolvedEffort, "max")
    }

    func testPendingPhoneChoiceSurvivesPreSendReadAndListRefresh() async {
        let transport = ModelSyncTransport()
        transport.deferSettings = true
        let store = AppCoordinator(transport: transport)
        let old = Thread(json: ["id": "model-sync", "model": "old-model"])!
        store.list.inject(threads: [old])
        store.list.currentID = old.id
        store.list.setModel("phone-choice")
        store.list.setEffort("high")
        store.list.applyThreads([old], dropPendingMissing: false)
        store.chat.send("你好")
        for _ in 0..<20 { await Task.yield() }
        let sent = transport.calls.first { $0.0 == "turn/start" }?.1
        XCTAssertEqual(store.list.resolvedModel, "phone-choice")
        XCTAssertEqual(sent?.str("model"), "phone-choice")
        XCTAssertEqual(sent?.str("effort"), "high")
        XCTAssertNil(sent?["reasoningEffort"])
        store.chat.close()
    }

    func testDelayedConfigurationKeepsFirstSendAndSecondDraft() async {
        let transport = ModelSyncTransport()
        transport.deferRead = true
        transport.completedTurn = true
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "model-sync", "model": "old-model"])!])
        store.list.currentID = "model-sync"
        store.composer.text = "第一条"
        store.composer.submit()
        let firstID = store.chat.sendingID
        store.chat.pollRemote("model-sync")
        for _ in 0..<12 { await Task.yield() }
        store.composer.text = "第二条"
        store.composer.submit()
        // 第一句在跑、回合 id 还没到手：第二条**排队**是设计行为
        // （不能 turn/start，那会多出一条一样的消息）。
        // 这里关心的是"第一条没被第二条顶掉"。
        XCTAssertEqual(store.chat.sendingID, firstID)
        transport.pendingRead?(.success(["thread": ["id": "model-sync", "model": "desktop-model"]] as JSONDict))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.calls.filter { $0.0 == "turn/start" }.count, 1)
        store.chat.close()
    }

    func testOverlappingConfigurationRefreshSharesPendingRead() async {
        let transport = ModelSyncTransport()
        transport.deferRead = true
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "model-sync", "model": "old-model"])!])
        store.list.currentID = "model-sync"
        store.chat.send("你好")
        let firstRead = transport.pendingRead
        store.list.refreshConfiguration(force: true)
        XCTAssertEqual(transport.calls.filter { $0.0 == "thread/read" }.count, 1)
        firstRead?(.success(["thread": ["id": "model-sync", "model": "desktop-model"]] as JSONDict))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.calls.first { $0.0 == "turn/start" }?.1.str("model"), "desktop-model")
        store.chat.close()
    }

    func testLateListCannotOverwriteConfirmedThreadConfiguration() async {
        let transport = ModelSyncTransport()
        let store = AppCoordinator(transport: transport)
        let old = Thread(json: ["id": "model-sync", "model": "old-model"])!
        store.list.inject(threads: [old])
        store.list.currentID = old.id
        store.list.refreshConfiguration(force: true)
        for _ in 0..<12 { await Task.yield() }
        store.list.applyThreads([old], dropPendingMissing: false)
        XCTAssertEqual(store.list.resolvedModel, "desktop-model")
        XCTAssertEqual(store.list.resolvedEffort, "max")
    }

    func testConfigurationWaitCanCancelAndDoesNotQueueRetry() async {
        let transport = ModelSyncTransport()
        transport.deferRead = true
        let store = AppCoordinator(transport: transport)
        store.list.inject(threads: [Thread(json: ["id": "model-sync"])!])
        store.list.currentID = "model-sync"
        store.chat.items = [.user(id: "old-failed", text: "旧消息", images: [])]
        store.chat.fail("old-failed", "发送失败")
        store.chat.send("第一条")
        let pendingID = store.chat.sendingID
        store.chat.retry("old-failed", text: "旧消息")
        store.chat.interrupt()
        transport.pendingRead?(.success(["thread": ["id": "model-sync", "model": "desktop-model"]] as JSONDict))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/queue/add" || $0.0 == "turn/start" })
        XCTAssertTrue(store.chat.failed.contains("old-failed"))
        XCTAssertEqual(store.chat.sendStates[pendingID ?? ""], .failed("已取消发送"))
        XCTAssertFalse(store.chat.configurationPreparing)
        store.chat.close()
    }

    func testKnownModelUsesCatalogName() {
        let s = makeStore()
        let m = ModelOption(json: ["id": "global:deepseek-v4.1-flash",
                                   "displayName": "DeepSeek 4.1 Flash"])!
        s.__testSeedModels([m])
        XCTAssertEqual(s.modelLabel("global:deepseek-v4.1-flash"), "DeepSeek 4.1 Flash")
        // 按 id 认不出时也要能按 name 认出来。
        XCTAssertEqual(s.modelLabel("DeepSeek 4.1 Flash"), "DeepSeek 4.1 Flash")
    }

    // MARK: 全局配置兜底（`config/read`）

    /// 电脑端 Codex 的模型来自 `~/.codex/config.toml` 的 `model`。
    /// App 从来不读它 —— 会话自己没记模型时界面就是空的，
    /// 看着就像"手机和电脑端不一致"。全局值必须能兜底。
    func testGlobalConfigFillsMissingThreadModel() {
        let s = makeStore()
        let t = Thread(json: ["id": "t1", "cwd": "/tmp"])!
        s.__testSeed(threads: [t], archived: [])
        s.currentID = "t1"
        s.__testSeedGlobal(model: "global:deepseek-v4.1-flash", effort: "max")
        XCTAssertEqual(s.resolvedModel, "global:deepseek-v4.1-flash")
        XCTAssertEqual(s.resolvedEffort, "max")
    }

    /// 会话自己记了模型就以会话为准 —— 全局只是兜底，不能覆盖。
    func testThreadModelWinsOverGlobal() {
        let s = makeStore()
        let t = Thread(json: ["id": "t1", "cwd": "/tmp",
                              "model": "gpt-6-astra", "reasoningEffort": "high"])!
        s.__testSeed(threads: [t], archived: [])
        s.currentID = "t1"
        s.__testSeedGlobal(model: "global:deepseek-v4.1-flash", effort: "max")
        XCTAssertEqual(s.resolvedModel, "gpt-6-astra")
        XCTAssertEqual(s.resolvedEffort, "high")
    }

    /// 空值不再直接说"默认模型"：有全局值就报全局值。
    func testModelLabelUsesGlobalWhenRawEmpty() {
        let s = makeStore()
        s.__testSeedGlobal(model: "global:deepseek-v4.1-flash", effort: "max")
        XCTAssertEqual(s.modelLabel(""), "global:deepseek-v4.1-flash")
    }

    /// 没有全局值也不能瞎编。
    func testNoGlobalStillSaysDefault() {
        let s = makeStore()
        XCTAssertEqual(s.resolvedModel, "")
    }

    /// 全局模型不在 `model/list` 目录里时，强度档位要从
    /// `config.desktop.enabled-reasoning-efforts` 撑起来，
    /// 否则「推理强度」整段是空的，用户没法选。
    func testEffortsFallBackToGlobalListWhenModelUnknown() {
        let s = makeStore()
        s.__testSeedGlobal(model: "global:deepseek-v4.1-flash", effort: "max")
        s.__testSeedEfforts(["low", "medium", "high", "max"])
        XCTAssertEqual(s.effortsFor("global:deepseek-v4.1-flash").map(\.id),
                       ["low", "medium", "high", "max"])
    }

    /// 目录里有这个模型就用目录自己的档位，别用全局那份。
    func testCatalogEffortsWinWhenModelKnown() {
        let s = makeStore()
        let m = ModelOption(json: ["id": "gpt-6-astra", "displayName": "GPT-6-Astra",
                                   "supportedReasoningEfforts": [
                                       ["reasoningEffort": "high", "displayName": "high"]],
                                   "defaultReasoningEffort": "high"])!
        s.__testSeedModels([m])
        s.__testSeedEfforts(["low", "max"])
        XCTAssertEqual(s.effortsFor("gpt-6-astra").map(\.id), ["high"])
    }

    /// `config/read` 的回包形状锁死：真机返回的是 `{config:{...}}`。
    func testParseGlobalConfigReadsRealPayloadShape() {
        let v: JSONDict = ["config": [
            "model": "global:deepseek-v4.1-flash",
            "model_reasoning_effort": "max",
            "desktop": ["enabled-reasoning-efforts": ["low", "medium", "high", "xhigh", "ultra", "max"]],
        ]]
        let p = ThreadListModel.parseGlobalConfig(v)
        XCTAssertEqual(p.model, "global:deepseek-v4.1-flash")
        XCTAssertEqual(p.effort, "max")
        XCTAssertEqual(p.efforts, ["low", "medium", "high", "xhigh", "ultra", "max"])
    }

    /// 回包缺字段不能崩，也不能编。
    func testParseGlobalConfigToleratesMissingFields() {
        let p = ThreadListModel.parseGlobalConfig([String: Any]())
        XCTAssertEqual(p.model, "")
        XCTAssertEqual(p.effort, "")
        XCTAssertTrue(p.efforts.isEmpty)
    }

    /// 历史配置仍照实显示，但不冒充当前服务商的可选模型。
    func testModelRowsOmitGlobalModelMissingFromCatalog() {
        let s = makeStore()
        let m = ModelOption(json: ["id": "gpt-6-astra", "displayName": "GPT-6-Astra"])!
        s.__testSeedModels([m])
        s.__testSeedGlobal(model: "global:deepseek-v4.1-flash", effort: "max")
        let rows = s.modelRows(current: "global:deepseek-v4.1-flash")
        XCTAssertEqual(rows.map(\.id), ["gpt-6-astra"])
    }

    func testUnknownConfiguredDefaultDoesNotEraseValidCatalog() {
        let s = makeStore()
        let stale = ModelOption(json: ["id": "global:deepseek-v4.1-flash"])!
        s.__testSeedModels([stale])
        s.__testSeedDefault(model: "global:deepseek-v4.1-flash", effort: "max")
        s.__testSeedGlobal(model: "gpt-6-astra", effort: "max")
        XCTAssertEqual(s.models.map(\.id), ["global:deepseek-v4.1-flash"])
        XCTAssertEqual(s.modelForNewThread, "global:deepseek-v4.1-flash")
    }

    /// 在目录里就不要重复插一行。
    func testModelRowsDoNotDuplicateCatalogEntry() {
        let s = makeStore()
        let m = ModelOption(json: ["id": "gpt-6-astra", "displayName": "GPT-6-Astra"])!
        s.__testSeedModels([m])
        XCTAssertEqual(s.modelRows(current: "gpt-6-astra").map(\.id), ["gpt-6-astra"])
    }

    /// 当前模型为空时不要插空行。
    func testModelRowsSkipEmptyCurrent() {
        let s = makeStore()
        let m = ModelOption(json: ["id": "gpt-6-astra", "displayName": "GPT-6-Astra"])!
        s.__testSeedModels([m])
        XCTAssertEqual(s.modelRows(current: "").map(\.id), ["gpt-6-astra"])
    }

    /// 手机新建的会话必须跟电脑端用同一个模型。
    /// 以前 `loadModels()` 会拿目录第一条（gpt-6.1-sol）当默认，
    /// 而电脑端 config.toml 里是 deepseek —— 新建出来就是两个模型。
    func testNewThreadFollowsDesktopGlobalModel() {
        let s = makeStore()
        let m = ModelOption(json: ["id": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol"])!
        s.__testSeedModels([m])
        s.__testSeedGlobal(model: "global:deepseek-v4.1-flash", effort: "max")
        XCTAssertEqual(s.modelForNewThread, "global:deepseek-v4.1-flash")
        XCTAssertEqual(s.effortForNewThread, "max")
    }

    /// 未设置默认值时交给服务端选择，模型目录首项不是用户选择。
    func testNewThreadLeavesUnspecifiedModelToServer() {
        let s = makeStore()
        let m = ModelOption(json: ["id": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol",
                                   "defaultReasoningEffort": "high"])!
        s.__testSeedModels([m])
        XCTAssertEqual(s.modelForNewThread, "")
        XCTAssertEqual(s.effortForNewThread, "")
    }

    /// 用户自己选过（`defaultModel` 非空）时不再被电脑端覆盖。
    func testExplicitDefaultStillWinsForNewThread() {
        let s = makeStore()
        s.__testSeedDefault(model: "gpt-6-astra", effort: "low")
        s.__testSeedGlobal(model: "global:deepseek-v4.1-flash", effort: "max")
        XCTAssertEqual(s.modelForNewThread, "gpt-6-astra")
        XCTAssertEqual(s.effortForNewThread, "low")
    }
}

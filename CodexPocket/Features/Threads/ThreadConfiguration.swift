import Foundation

extension ThreadListModel {
    private func updateConfiguration(_ id: String, model: String? = nil, effort: String? = nil) {
        func update(_ row: inout Thread) {
            if let model { row.model = model }
            if let effort { row.effort = effort }
        }
        if let i = threads.firstIndex(where: { $0.id == id }) { update(&threads[i]) }
        if let i = archived.firstIndex(where: { $0.id == id }) { update(&archived[i]) }
        if let pending = pendingNew[id] {
            var row = pending.0
            update(&row)
            pendingNew[id] = (row, pending.1)
        }
    }

    func setEffort(_ e: String) {
        guard let t = currentID else { return }
        updateConfiguration(t, effort: e)
        writeConfiguration(["threadId": t, "effort": e], threadID: t)
    }

    /// 给**这个会话**换模型。
    ///
    /// 以前这里顺手把 `settings.defaultModel` 也改了 —— 在某个会话里
    /// 挑一次模型，之后所有**新**会话都跟着变，用户根本没要求。
    /// 会话的模型只属于会话自己；全局默认在设置里单独改。
    func setModel(_ id: String) {
        guard let t = currentID else { return }
        updateConfiguration(t, model: id)
        writeConfiguration(["threadId": t, "model": id], threadID: t)
    }

    /// 外部连接上的 `thread/settings/updated` 通知。
    /// `effort: null` 是清除覆盖值，不能保留旧值。
    func applyConfigurationEvent(_ payload: JSONDict) {
        guard let id = payload.str("threadId"), let values = payload.dict("threadSettings") else { return }
        let model = values.str("model")
        let effort: String? = values.keys.contains("effort") ? (values.str("effort") ?? "") : nil
        guard model != nil || effort != nil else { return }
        // 这条事件代表电脑端已经写入了新配置。
        // 递增代次，令在途的旧 `thread/read` 回包失效；否则旧回包会把
        // 刚同步到手机的新模型覆盖回旧模型（老会话换模型最容易撞到）。
        configurationChanges += 1
        updateConfiguration(id, model: model, effort: effort)
        if id == currentID { confirmedConfigurationID = id }
    }

    private func writeConfiguration(_ values: JSONDict, threadID: String) {
        confirmedConfigurationID = threadID
        configurationChanges += 1
        configurationWrites[threadID, default: 0] += 1
        repository.perform(.settings(values)) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.configurationWrites[threadID, default: 1] -= 1
                if self.configurationWrites[threadID] == 0 {
                    self.configurationWrites.removeValue(forKey: threadID)
                }
                if case .failure(let error) = result {
                    self.banner = "会话配置没改成功：" + error.localizedDescription
                    self.refreshConfiguration(force: true)
                }
            }
        }
    }

    /// 服务端报的模型名 → 界面上显示的名字。
    ///
    /// 会话里存的模型可能**不在** `model/list` 里（CC Switch 切供应商之后
    /// 目录只剩一个，老会话还记着旧的）。这时不能显示成"默认模型" ——
    /// 那会让人以为手机和电脑端不一致（用户就是这么问的）。
    /// 直接把服务端的原值摆出来，至少能对上号。
    func modelLabel(_ raw: String) -> String {
        // 空值先用电脑端的全局模型兜底，再退到"默认模型"。
        let v = raw.isEmpty ? globalModel : raw
        guard !v.isEmpty else { return "默认模型" }
        // 目录里有就按目录的 displayName（更短更好看）。
        if let m = models.first(where: { $0.id == v || $0.name == v }) {
            return m.name
        }
        return v
    }

    /// 当前会话**实际**在用的模型：会话自己记的优先，没有就用电脑端全局值。
    var resolvedModel: String {
        let own = thread(currentID ?? "")?.model ?? ""
        return own.isEmpty ? globalModel : own
    }

    /// 当前会话**实际**在用的推理强度。同理，全局值兜底。
    var resolvedEffort: String {
        let own = thread(currentID ?? "")?.effort ?? ""
        if !own.isEmpty { return own }
        if !globalEffort.isEmpty { return globalEffort }
        return settings.defaultEffort
    }

    /// 从 `config/read` 回包里取全局模型 / 强度 / 档位。
    ///
    /// 抽成纯函数是为了能单测 —— 真正的调用点在一个 RPC 回调里。
    static func parseGlobalConfig(_ v: Any)
        -> (model: String, effort: String, efforts: [String]) {
        let top = v as? JSONDict
        let cfg = top?.dict("config") ?? top ?? [:]
        let efforts = cfg.dict("desktop")?.strs("enabled-reasoning-efforts")
            ?? cfg.dict("desktop")?.strs("enabled_reasoning_efforts")
            ?? []
        return (cfg.str("model") ?? "",
                cfg.str("model_reasoning_effort") ?? "",
                efforts)
    }

    /// 新建会话该用的模型。
    ///
    /// 用户自己选过（`defaultModel` 非空）就用它；否则跟电脑端走 ——
    /// 以前这里拿的是 `model/list` 目录第一条（实测是 `gpt-6.1-sol`），
    /// 而电脑端 config.toml 里是 `global:deepseek-v4.1-flash`，
    /// 于是手机新建的会话和电脑端是两个模型。
    var modelForNewThread: String {
        if !settings.defaultModel.isEmpty { return settings.defaultModel }
        if !globalModel.isEmpty { return globalModel }
        return ""
    }

    /// 新建会话该用的推理强度。同理，用户选过优先，否则跟电脑端。
    var effortForNewThread: String {
        if !settings.defaultEffort.isEmpty { return settings.defaultEffort }
        if !globalEffort.isEmpty { return globalEffort }
        return ""
    }

    /// 配置页要显示的模型行。
    ///
    /// 可选项只来自服务端目录；历史会话模型仍由 modelLabel 照实显示。
    func modelRows(current: String) -> [ModelOption] {
        // 这里必须只显示当前服务商返回的目录。以前为了让旧会话有勾选项，
        // 把不在目录里的 globalModel 人工插入，CC Switch 切换配置后就会把
        // 上一个服务商的 deepseek 继续显示出来。
        return models
    }

    /// 某个模型能选的推理强度档位。
    ///
    /// 目录里有就信目录；没有（切过供应商 / 全局模型不在目录里）就用
    /// `config.desktop.enabled-reasoning-efforts` —— 否则整段是空的。
    func effortsFor(_ modelId: String) -> [EffortOption] {
        let v = modelId.isEmpty ? globalModel : modelId
        if let m = models.first(where: { $0.id == v || $0.name == v }), !m.efforts.isEmpty {
            return m.efforts
        }
        return globalEfforts.map { EffortOption(id: $0, name: $0) }
    }

    /// 只读同步，不加载会话或申请写者锁。沿用已有轮询，最多每 20 秒一次。
    func refreshConfiguration(force: Bool = false, done: (() -> Void)? = nil) {
        guard repository.isReady else { done?(); return }
        loadModels(force: false)
        let id = currentID
        if let pending = configurationInFlight, pending.id == id {
            if let done { configurationCallbacks[pending.sequence, default: []].append(done) }
            return
        }
        if !force, let last = configurationRead, last.id == id,
           Date().timeIntervalSince(last.at) < reconcileInterval { done?(); return }
        configurationRead = (id, Date())
        configurationReadSeq += 1
        let sequence = configurationReadSeq
        configurationInFlight = (id, sequence)
        configurationCallbacks[sequence] = done.map { [$0] } ?? []
        let changes = configurationChanges
        var remaining = id == nil ? 1 : 2
        func completed() {
            remaining -= 1
            guard remaining == 0 else { return }
            if self.configurationInFlight?.sequence == sequence { self.configurationInFlight = nil }
            let callbacks = self.configurationCallbacks.removeValue(forKey: sequence) ?? []
            callbacks.forEach { $0() }
        }
        loadGlobalConfig(done: completed)
        guard let id else { return }
        let writing = configurationWrites[id] != nil
        repository.readThread(id) { [weak self] result in
            Task { @MainActor in
                defer { completed() }
                guard let self, self.currentID == id, self.configurationReadSeq == sequence,
                      self.configurationChanges == changes, !writing, self.configurationWrites[id] == nil,
                      case .success(let fresh) = result else { return }
                self.applyConfiguration(fresh)
            }
        }
    }

    func loadGlobalConfig(done: (() -> Void)? = nil) {
        let sequence = configurationReadSeq
        repository.perform(.config) { [weak self] r in
            Task { @MainActor in
                defer { done?() }
                guard let self, self.configurationReadSeq == sequence,
                      case .success(let v) = r else { return }
                let p = Self.parseGlobalConfig(v)
                self.globalModel = p.model
                self.globalEffort = p.effort
                self.globalEfforts = p.efforts
            }
        }
    }

    private func applyConfiguration(_ fresh: Thread) {
        confirmedConfigurationID = fresh.id
        updateConfiguration(fresh.id, model: fresh.model, effort: fresh.effort)
    }
}

// MARK: - 跨进程对账

extension ThreadListModel {
    /// 隔多久跟服务端对一次账。
    ///
    /// 为什么必须轮询，不能只靠事件：`thread/archived` / `thread/deleted` /
    /// `turn/completed` 这些通知**只发给发起变更的那条连接，不广播**
    /// （实测：两个 app-server 分别连上去，一个归档，只有它自己收到
    /// `thread/archived`，另一条连接什么都没收到）。
    ///
    /// 桌面 Codex 和手机桥接跑的是**两个不同的 app-server 进程**，
    /// 所以电脑端归档 / 删除 / 新建会话，手机端一条事件都收不到 ——
    /// 表现就是"电脑端归档了手机看不到""电脑端新建的会话手机没有"。
    /// 服务端状态是唯一可信来源，定期重拉一次最省事也最准。
}

/// 隔多久跟服务端对一次账（见 `ThreadListModel.startReconcile`）。
///
/// 放在文件作用域而不是类里：Timer 的回调是 nonisolated 的，
/// 读 `@MainActor` 类的 static 属性会报
/// "reference to captured var 'self' in concurrently-executing code"。
///
/// 8 秒 → 20 秒：对账一次要发 2 个请求（活跃首页 + 归档首页），
/// 8 秒一轮就是 15 个/分钟。电脑端改动的可见延迟从 8 秒变 20 秒，
/// 换来的是待机耗电直接砍掉一多半 —— 用户报的是耗电，不是延迟。
let reconcileInterval: TimeInterval = 20
/// 连续几次拉不到就放弃（App 被切到后台时没必要继续跑）。
let reconcileGiveUp = 3

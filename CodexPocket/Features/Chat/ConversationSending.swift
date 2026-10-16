import Foundation



extension ConversationModel {
    /// 图片 → `turn/start` 的 input 条目。
    ///
    /// 必须是 `localImage` + `path`：实测服务端的 UserInput 只认
    /// `text`/`image`/`localImage`/`audio`/`localAudio`/`skill`/`mention`，
    /// 而 `image` 的两个变体是 `url` 和 `fileId`。给 `image` 配 `path`
    /// 会回 "Invalid request: data did not match any variant of untagged
    /// enum ImageReference"，**整个回合都不执行** —— 这就是用户报的
    /// "带图片发送不成功"。空路径（还没传上去）直接丢掉。
    static func imageInput(_ paths: [String]) -> [JSONDict] {
        paths.filter { !$0.isEmpty }.map { ["type": "localImage", "path": $0] }
    }

    /// 把 U+2028 / U+2029 换成普通换行。
    ///
    /// 兼容旧桥接的逐行 JSON 读取：将 Unicode 分隔符归一为换行。
    ///
    /// 旧桥接使用 node:readline 时会误拆 JSON 字符串内的 U+2028/U+2029，
    /// 导致 RPC 回包不完整、会话打开一直等待。桥接现已改为只按 LF 分帧；
    /// 手机保留归一化，以兼容尚未升级的桥接。
    nonisolated static func cleanText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value == 0x2028 || $0.value == 0x2029 }) else {
            return text
        }
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    /// 发一条消息。乐观插入，失败标红可重试。
    func send(_ rawText: String, images: [String] = [], localID: String? = nil) {
        guard !configurationPreparing else { return }
        // 统一旧桥接可能误处理的 Unicode 行分隔符。
        let text = Self.cleanText(rawText)
        guard let id = list.currentID, !text.isEmpty || !images.isEmpty else { return }
        let localId = localID ?? "local-\(UUID().uuidString)"
        guard !activeSubmissionIDs.contains(localId), !acceptedSubmissionIDs.contains(localId) else { return }
        activeSubmissionIDs.insert(localId)
        if !items.contains(where: { $0.id == localId }) {
            items.append(.turnBreak(id: "tb-local-\(UUID().uuidString)", at: Date(), duration: nil))
            items.append(.user(id: localId, text: text, images: images))
        }
        markSending(localId)
        tick += 1
        sendSeq += 1

        if busy {
            lastSendWhy = "busy→排队"
            enqueueRemote(threadId: id, text: text, images: images, localId: localId)
            return
        }
        lastSendWhy = "send→startTurn"
        startTurn(threadId: id, text: text, images: images, localId: localId)
        saveCache()
    }

    /// The transaction keeps its original thread and parameters across navigation.
    func startTurn(threadId: String, text: String, images: [String],
                   localId: String, attempt: Int = 0, lockTry: Int = 0,
                   configurationReady: Bool = false) {
        let namespace = repository.cache.namespace
        let session = openSeq
        let ownModel = list.thread(threadId)?.model ?? ""
        let ownEffort = list.thread(threadId)?.effort ?? ""
        let model = ownModel.isEmpty ? list.globalModel : ownModel
        let effort = ownEffort.isEmpty ? (list.globalEffort.isEmpty ? settings.defaultEffort : list.globalEffort) : ownEffort
        activeSubmissionIDs.insert(localId)
        // 归属按会话记 —— 回合是我们发起的，跟"此刻看没看着这个会话"无关。
        ownedTurnThreads.insert(threadId)
        if list.currentID == threadId {
            if sendingID != localId { stopRequested = false }
            sendingID = localId
            configurationPreparing = !configurationReady
            busy = true
        }
        func prepared() {
            guard self.repository.cache.namespace == namespace else { return }
            if self.cancelSubmissionIfRequested(threadId: threadId, localId: localId) { return }
            let visible = self.openSeq == session && self.list.currentID == threadId
            if visible {
                self.configurationPreparing = false
                if self.stopRequested {
                    self.stopRequested = false; self.busy = false
                    self.fail(localId, "已取消发送")
                    return
                }
            }
            var input = Self.imageInput(images)
            if !text.isEmpty { input.insert(["type": "text", "text": text], at: 0) }
            var params: JSONDict = ["threadId": threadId, "input": input, "clientUserMessageId": localId]
            let selectedModel = visible ? self.list.resolvedModel : model
            let selectedEffort = visible ? self.list.resolvedEffort : effort
            if !selectedModel.isEmpty { params["model"] = selectedModel }
            if !selectedEffort.isEmpty { params["effort"] = selectedEffort }
            self.resumeSubmission(threadId: threadId, text: text, images: images, localId: localId,
                                  params: params, session: session, namespace: namespace, lockTry: lockTry)
        }
        if configurationReady { prepared() }
        else { list.refreshConfiguration(force: true, done: prepared) }
    }

    private func resumeSubmission(threadId: String, text: String, images: [String], localId: String,
                                  params: JSONDict, session: Int, namespace: String, lockTry: Int) {
        guard repository.cache.namespace == namespace else { return }
        repository.perform(.resume(["threadId": threadId, "excludeTurns": true])) { [weak self] result in
            Task { @MainActor in
                guard let self, self.repository.cache.namespace == namespace else { return }
                if self.cancelSubmissionIfRequested(threadId: threadId, localId: localId) { return }
                let visible = self.openSeq == session && self.list.currentID == threadId
                if visible, self.stopRequested {
                    self.stopRequested = false; self.busy = false
                    self.forgetTurn(threadId)
                    self.fail(localId, "已取消发送"); return
                }
                if case .failure(let error) = result {
                    let message = error.localizedDescription
                    if message.contains("active writer"), lockTry < 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                            self?.resumeSubmission(threadId: threadId, text: text, images: images,
                                localId: localId, params: params, session: session,
                                namespace: namespace, lockTry: lockTry + 1)
                        }
                        return
                    }
                    if !message.contains("no rollout found") && !message.contains("active writer") {
                        if visible { self.busy = false }
                        self.forgetTurn(threadId)
                        self.fail(localId, message)
                        return
                    }
                }
                // 拿到写者锁了（resume 成功）→ 这个会话没被电脑端占着。
                // **不管 visible**：锁是按会话的，切走了也得记下来，
                // 不然切回来还按"被占着"走排队。
                self.desktopLockedThreads.remove(threadId)
                self.ownedTurnThreads.insert(threadId)
                self.activeTurnIds[threadId] = nil
                if visible {
                    self.turnStarted = Date()
                    self.busy = true
                }
                self.sendTurn(threadId: threadId, text: text, images: images,
                              localId: localId, params: params, attempt: 0)
            }
        }
    }

    func sendTurn(threadId: String, text: String, images: [String],
                  localId: String, params: JSONDict, attempt: Int) {
        let session = openSeq
        let namespace = repository.cache.namespace
        repository.perform(.start(params)) { [weak self] result in
            Task { @MainActor in
                guard let self, self.repository.cache.namespace == namespace else { return }
                let visible = self.openSeq == session && self.list.currentID == threadId
                if case .success(let value) = result {
                    self.acknowledgeSubmission(value, threadId: threadId, localId: localId, visible: visible)
                    return
                }
                guard case .failure(let error) = result else { return }
                let message = error.localizedDescription
                if visible { self.busy = false; self.lastSendWhy = "turn/start:" + message.prefix(30) }
                self.forgetTurn(threadId)
                // **电脑端正跑着这个会话**（写者锁在它手里）：`turn/start`
                // 回 "thread XX already has an active writer"（实测）。
                //
                // 以前这里直接把消息标红「释放后重试」—— 用户看到的就是
                // 「发出去没反应/报错」。其实那边真有回合在跑时能**插话**：
                // 实测（2026-10-14，真桥接 62113）`turn/steer` 成功，
                // 插话那句进模型并改变答复。所以先问一次有没有在跑的回合，
                // 有就插进去；真没有才报错（没人跑的队列不会被任何人执行）。
                if message.contains("active writer") {
                    self.desktopLockedThreads.insert(threadId)
                    self.resolveActiveTurn(threadId: threadId) { [weak self] resolved in
                        Task { @MainActor in
                            guard let self, self.repository.cache.namespace == namespace else { return }
                            guard let resolved else {
                                self.fail(localId, "会话仍被电脑端占用，释放后重试")
                                return
                            }
                            self.activeTurnIds[threadId] = resolved
                            self.steerWith(turnId: resolved, threadId: threadId, text: text,
                                           images: images, localId: localId)
                        }
                    }
                    return
                }
                let code = (error as? WebSocketTransport.RPCError)?.code
                if [-32600, -32601, -32602, -32092, -32093].contains(code ?? 0)
                    || message.contains("还没连上电脑") {
                    self.fail(localId, message)
                } else {
                    if visible {
                        self.pendingSend = (localId, text)
                        self.markConfirming(localId)
                    }
                    self.confirmSubmission(threadId: threadId, localId: localId, text: text, images: images)
                }
            }
        }
    }

    private func acknowledgeSubmission(_ value: Any, threadId: String, localId: String, visible: Bool) {
        let turn = (value as? JSONDict)?.dict("turn")
        let id = turn?.str("id") ?? (value as? JSONDict)?.str("turnId")
        accept(localId)
        // **归属与活动回合 id 按会话记，跟 visible 无关。**
        // 以前这段在 `guard visible` 后面 —— 切走的会话虽然发出去了，
        // 归属却没落下来，切回来就变成"不知道是谁的回合"，插话降级成排队。
        var completed = false
        if let id {
            completed = completedTurnIDs.contains(id)
                || turn?.str("status") == "completed"
                || turn?.str("status") == "interrupted"
                || turn?.str("status") == "failed"
            if completed {
                if activeTurnIds[threadId] == nil || activeTurnIds[threadId] == id { forgetTurn(threadId) }
            }
            else {
                ownedTurnThreads.insert(threadId)
                activeTurnIds[threadId] = id
            }
        }
        if cancelledSubmissionIDs.remove(localId) != nil, !completed, let id {
            if visible { stopRequested = false }
            sendInterrupt(threadId: threadId, turnId: id)
        }
        guard visible, sendingID == localId || sendingID == nil else { return }
        if let id {
            lastTurnId = id
            if !completed { busy = true; localTurn = true } else { busy = false }
        }
        if stopRequested, let turnId = serverTurnId {
            sendInterrupt(threadId: threadId, turnId: turnId)
        }
    }

    /// 回合运行中插一句话纠正方向，不打断。
    func steer(_ rawText: String, images: [String] = [], localID: String? = nil) {
        let namespace = repository.cache.namespace
        let text = Self.cleanText(rawText)          // 同上：别把 U+2028 写进去
        guard let id = list.currentID, !text.isEmpty || !images.isEmpty else { return }
        let localId = localID ?? "local-\(UUID().uuidString)"
        guard !activeSubmissionIDs.contains(localId), !acceptedSubmissionIDs.contains(localId) else { return }
        activeSubmissionIDs.insert(localId)
        // **"电脑端占着 → 插话做不到"是错的，实测过了。**
        //
        // 2026-10-14 用真桥接（62113）+ 真服务端量：
        //   - 桌面端起一个回合（写者锁在它手里）；
        //   - 手机端 `turn/steer` 回 OK，那句插话进模型，
        //     最终答复按插话改成了「插话到了」；
        //   - 占锁只挡 `thread/resume`（回 "active writer"），
        //     不挡 `turn/steer`。
        // 所以这里不再预先降级成排队 —— 直接插，失败才由
        // `steerWith` 的失败分支兜底转排队。
        if !items.contains(where: { $0.id == localId }) {
            items.append(.user(id: localId, text: text, images: images))
        }
        markSending(localId)
        tick += 1
        sendSeq += 1
        // **`expectedTurnId` 是必填的。**
        //
        // 少了它服务端直接回 "Invalid request: missing field `expectedTurnId`"
        // （实测），于是每一次插话都失败 → 走 `fallbackAfterSteer` 降级成
        // `turn/start` 新开一个回合。用户看到的就是：插话没插进去，
        // 反而多出**两条一模一样的消息**（本地那条 + 服务端回显那条）。
        guard let turnId = serverTurnId else {
            // 还不知道活动回合 id（刚切回这个会话、或者 app 刚重启）。
            //
            // 以前这里直接排队 —— 用户报的正是「一直在一个会话里插话能用，
            // 我一切出去插话就变成排队了」。插话不需要猜：`thread/turns/list`
            // 一问就有活动回合 id。先问，再插。
            //
            // **不能退回 `turn/start`**：那会另起一个回合，服务端再把这条
            // 用户消息回显回来 —— 界面上就是两条一样的（「一下发两个」）。
            resolveActiveTurn(threadId: id) { [weak self] resolved in
                Task { @MainActor in
                    guard let self, self.repository.cache.namespace == namespace else { return }
                    guard let resolved else {
                        // 真没有活动回合（或者问不到）：排到服务端队列。
                        self.enqueueRemote(threadId: id, text: text, images: images, localId: localId)
                        return
                    }
                    self.activeTurnIds[id] = resolved
                    self.steerWith(turnId: resolved, threadId: id, text: text,
                                   images: images, localId: localId)
                }
            }
            return
        }
        steerWith(turnId: turnId, threadId: id, text: text, images: images, localId: localId)
    }

    /// 问服务端要这个会话当前的活动回合 id。
    ///
    /// `turn/steer` 的 `expectedTurnId` 必填，切会话 / 重启后本地没有这个
    /// id，就得现问一次。`thread/turns/list` 直接能给（`interrupt()` 也是
    /// 这么问的）。
    func resolveActiveTurn(threadId: String, done: @escaping (String?) -> Void) {
        let namespace = repository.cache.namespace
        repository.perform(.turns(["threadId": threadId, "limit": 3,
                                   "sortDirection": "desc", "itemsView": "summary"])) {
            [weak self] r in
            Task { @MainActor in
                guard let self, self.repository.cache.namespace == namespace else {
                    done(nil); return
                }
                guard case .success(let v) = r,
                      let turns = (v as? JSONDict)?.dicts("data"),
                      let live = turns.first(where: { Self.isActive($0) }),
                      let t = live.str("id") else { done(nil); return }
                done(t)
            }
        }
    }

    /// 带已知 turnId 真正发插话。
    func steerWith(turnId: String, threadId id: String, text: String,
                   images: [String], localId: String) {
        var input = Self.imageInput(images)
        if !text.isEmpty { input.insert(["type": "text", "text": text], at: 0) }
        let session = openSeq
        let namespace = repository.cache.namespace
        let running = busy
        repository.perform(.steer(["threadId": id,
                               "expectedTurnId": turnId,
                               "clientUserMessageId": localId,
                               "input": input])) { [weak self] r in
            Task { @MainActor in
                guard let self, self.repository.cache.namespace == namespace else { return }
                let visible = self.openSeq == session && self.list.currentID == id
                if case .success = r { self.accept(localId); return }
                if case .failure(let e) = r {
                    let m = e.localizedDescription
                    if visible { self.lastSendWhy = "steer:" + m.prefix(40) }
                    // 会话不在我们这条 app-server 里（电脑端进程占着它）：
                    // 插话不可能成功，别再降级重发 —— 那正是「一下发两个」。
                    if m.contains("thread not found") || m.contains("active writer") {
                        // 会话在**别的进程**手里（电脑端占着这个回合）。
                        // 插话物理上做不到 —— 实测回 "thread not found"。
                        // 但共享队列是通的：电脑端跑完当前回合就会执行它
                        // （实测）。所以别把这句丢掉、也别标红，转排队。
                        if visible { self.desktopLocked = true }
                        if running {
                            // 真有回合在跑 → 队列会被持锁那边执行（实测：
                            // queue/add 成功，电脑端跑完当前回合就执行它）。
                            if visible { self.lastSendWhy = "steer→排队(电脑端占着)" }
                            self.enqueueRemote(threadId: id, text: text, images: images,
                                               localId: localId)
                            return
                        }
                        // 没人在跑：队列不会被任何人执行，别承诺。
                        self.fail(localId, "会话仍被电脑端占用，释放后重试")
                        return
                    }
                    if [-32600, -32601, -32602, -32092, -32093].contains((e as NSError).code) {
                        self.fail(localId, m); return
                    }
                }
                self.fallbackAfterSteer(threadId: id, text: text, images: images, localId: localId)
            }
        }
    }

    /// `turn/steer` 失败之后怎么办。
    ///
    /// 不能直接降级成 `turn/start` —— 失败可能只是回包丢了（连接断），
    /// 而服务端其实已经收到并执行了。直接降级会把同一句话跑两遍。
    /// 先拉一次服务端状态：里面已经有这条用户消息，就说明 steer 成功了。
    func fallbackAfterSteer(threadId: String, text: String, images: [String],
                            localId: String, tries: Int = 0) {
        if list.currentID == threadId {
            pendingSend = (localId, text)
            markConfirming(localId)
        }
        confirmSubmission(threadId: threadId, localId: localId, text: text, images: images)
    }

    /// 中断当前回合。**必须带 turnId** —— 只给 threadId 服务端会拒
    /// （实测 "Invalid request: missing field `turnId`"）。
    /// 停掉当前回合。
    ///
    /// 两个必须（都是实测出来的）：
    ///   1. `turnId` **必填**。不带字段直接回
    ///      "Invalid request: missing field `turnId`"。
    ///   2. 必须用**服务端给的**那个 id。带本地造的 id 回
    ///      "expected active turn id X but found Y"，停止照样失败 ——
    ///      这就是用户报的"暂停点了没用"。
    /// 所以：先问服务端要当前活动回合，再拿它的 id 去停。
    func interrupt() {
        guard let id = list.currentID else { return }
        if configurationPreparing {
            if let id = sendingID { cancelledSubmissionIDs.insert(id) }
            stopRequested = true
            return
        }
        if localTurn, serverTurnId == nil {
            if let id = sendingID { cancelledSubmissionIDs.insert(id) }
            stopRequested = true
            return
        }
        if let t = serverTurnId {
            sendInterrupt(threadId: id, turnId: t)
            return
        }
        // 还不知道 id（电脑端发起的回合，或者刚打开会话）：
        // 先查一次再停，不要拿本地那个假 id 去撞。
        let session = openSeq
        repository.perform(.turns(["threadId": id, "limit": 3,
                                      "sortDirection": "desc",
                                      "itemsView": "summary"])) { [weak self] r in
            Task { @MainActor in
                guard self?.openSeq == session, self?.list.currentID == id else { return }
                guard let self else { return }
                var turns: [JSONDict] = []
                if case .failure(let error) = r {
                    self.banner = "停止失败：" + error.localizedDescription
                    return
                }
                if case .success(let v) = r {
                    turns = (v as? JSONDict)?.dicts("data") ?? []
                }
                guard let live = turns.first(where: { Self.isActive($0) }),
                      let t = live.str("id") else {
                    self.busy = false
                    self.forgetTurn(id)
                    self.banner = "现在没有在跑的回合"
                    return
                }
                self.activeTurnIds[id] = t
                self.sendInterrupt(threadId: id, turnId: t)
            }
        }
    }

    /// 服务端报的回合状态是不是"正在跑"。
    ///
    /// 见过两种形态：`status: "inProgress"`（字符串）和
    /// `status: { type: "active" }`（对象）。只认一种就会漏。
    static func isActive(_ turn: JSONDict) -> Bool {
        let s = turn.str("status") ?? turn.dict("status")?.str("type") ?? ""
        return s == "inProgress" || s == "active" || s == "running"
    }

    func sendInterrupt(threadId: String, turnId: String) {
        let session = openSeq
        let namespace = repository.cache.namespace
        repository.perform(.interrupt(["threadId": threadId, "turnId": turnId])) {
            [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.repository.cache.namespace == namespace,
                      self.activeTurnIds[threadId] == turnId else { return }
                if case .failure(let e) = r {
                    // 停止失败要说出来 —— 之前是静默吞掉，
                    // 界面上按钮弹回去了但任务还在跑，用户以为点了没用。
                    if self.openSeq == session && self.list.currentID == threadId {
                        self.banner = "停止失败：" + e.localizedDescription
                    }
                    return
                }
                self.forgetTurn(threadId)
                if self.openSeq == session && self.list.currentID == threadId {
                    self.stopRequested = false
                    self.sendingID = nil
                    self.busy = false
                }
            }
        }
    }

    func compact() {
        guard let id = list.currentID else { return }
        repository.perform(.compact(["threadId": id])) { _ in }
    }

    /// 分叉：从这条助手回复处分出新会话。
    func fork() {
        guard let id = list.currentID else { return }
        let session = openSeq
        repository.perform(.fork(["threadId": id])) { [weak self] r in
            Task { @MainActor in
                guard self?.openSeq == session, self?.list.currentID == id else { return }
                guard let self else { return }
                if case .success = r {
                    self.banner = "已分叉出新会话"
                    self.list.load()
                }
            }
        }
    }

    /// 判定一条"发送结果未知"的消息到底有没有送达。
    ///
    /// 断线时 `turn/start` 的回包会丢，但消息通常已经到服务端并开始执行
    /// （实测：通知都发出来了，界面还写着"没发出去"）。所以不能凭回包
    /// 判断，要看服务端有没有这条用户消息。
    /// 服务端回合里有没有这条用户消息。
    ///
    /// 用来判定"回包丢了、但消息其实已经送达" —— 断线时 turn/start 和
    /// turn/steer 的回包都会丢，可服务端往往已经收到了。凭回包判断会
    /// 误判成失败，用户一点重试就重复执行一遍。
    /// 两条用户消息是不是同一句。
    ///
    /// 服务端回读的文本**带尾换行**（实测 `"…还卡死了\n"`），本地那条是
    /// 输入框 trim 过的。直接 `==` 比不出来 —— 本地气泡替换不掉，服务端
    /// 那份又插进来，界面上就是**两条一模一样的消息**（用户报的
    /// "自动发送两条一样的消息"）。
    nonisolated static func sameText(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func containsUser(_ text: String, in items: [Item]) -> Bool {
        return items.contains {
            if case .user(_, let t, _) = $0 { return sameText(t, text) }
            return false
        }
    }

    func containsSubmission(_ result: Any, localId: String, text: String, images: [String]) -> Bool {
        guard let d = result as? JSONDict else { return false }
        let turns = d.dicts("data") ?? d.dicts("turns") ?? []
        for turn in turns {
            for item in turn.dicts("items") ?? [] where item.str("type") == "userMessage" {
                if (item.str("clientId") ?? item.str("clientUserMessageId")) == localId { return true }
            }
        }
        return false
    }

    /// 往上翻：多加载一页更早的回合。
    ///
    /// `hasOlder` 以前只被赋值、从来没被读过 —— 长会话永远只能看到最近
    /// 12 条，往上滑什么都没有。用户说的"一直获取不完整"就是这个。
    func loadOlder() {
        guard list.currentID != nil, hasOlder, !loadingOlder, loadedTurns < 300 else { return }
        loadingOlder = true
        loadedTurns = min(loadedTurns + Self.pageSize, 300)
        reload(limit: loadedTurns)
    }

    nonisolated static func hasMoreTurns(_ result: Any, limit: Int) -> Bool {
        guard let data = result as? JSONDict else { return false }
        if data.keys.contains("nextCursor") {
            return !(data.str("nextCursor") ?? "").isEmpty
        }
        return ((data["data"] ?? data["turns"]) as? [Any] ?? []).count >= limit
    }

    func confirmPending() {
        guard let pending = pendingSend, let id = list.currentID else { return }
        markConfirming(pending.id)
        confirmSubmission(threadId: id, localId: pending.id, text: pending.text, images: [])
    }

    func confirmSubmission(threadId: String, localId: String, text: String, images: [String]) {
        uncertainSubmissionIDs.insert(localId)
        guard submissionChecks.insert(localId).inserted else { return }
        let namespace = repository.cache.namespace
        let session = openSeq
        repository.perform(.submissionStatus(["threadId": threadId, "clientUserMessageId": localId])) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                guard self.repository.cache.namespace == namespace else {
                    self.submissionChecks.remove(localId); return
                }
                var state: String?
                if case .success(let value) = result, let status = value as? JSONDict {
                    state = status.str("state")
                    if state == "accepted", let payload = status.dict("result"), let value = payload["result"] {
                        self.submissionChecks.remove(localId)
                        self.acknowledgeSubmission(value, threadId: threadId, localId: localId,
                            visible: self.openSeq == session && self.list.currentID == threadId)
                        return
                    }
                    if state == "pending" { self.submissionChecks.remove(localId); return }
                }
                self.repository.perform(.turns(["threadId": threadId, "limit": 8,
                    "sortDirection": "desc", "itemsView": "full"])) { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.repository.cache.namespace == namespace,
                              case .success(let history) = result else {
                            self.submissionChecks.remove(localId); return
                        }
                        if self.containsSubmission(history, localId: localId, text: text, images: images) {
                            self.accept(localId)
                            self.submissionChecks.remove(localId)
                            if self.openSeq == session && self.list.currentID == threadId {
                                self.mergeTail(Protocol_.items(fromTurns: history))
                            }
                            return
                        }
                        self.repository.perform(.queueList(["threadId": threadId])) { [weak self] result in
                            Task { @MainActor in
                                defer { self?.submissionChecks.remove(localId) }
                                guard let self, self.repository.cache.namespace == namespace,
                                      case .success(let value) = result,
                                      let rows = (value as? JSONDict)?.dicts("data") else { return }
                                if rows.contains(where: { $0.str("clientUserMessageId") == localId }) {
                                    self.accept(localId)
                                    if self.openSeq == session && self.list.currentID == threadId { self.markQueued(localId) }
                                } else if state == "missing", self.activeSubmissionIDs.contains(localId),
                                          (history as? JSONDict)?["data"] is [JSONDict] {
                                    self.fail(localId, "服务端未收到这条消息，请重试")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

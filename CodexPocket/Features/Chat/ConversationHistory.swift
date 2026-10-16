import Foundation

/// turns/list 可能夹带图片 data URL；协议解析会复制/扫描整段正文，不能在
/// MainActor 上做，否则打开含图片的长会话时 SwiftUI 会完全失去响应。
func parseConversationItemsOffMain(_ payload: Any,
                                   done: @escaping ([Item]) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let parsed = Protocol_.items(fromTurns: payload)
        DispatchQueue.main.async { done(parsed) }
    }
}

extension ConversationModel {


    func open(_ t: Thread) { open(id: t.id, running: t.running) }

    /// 按 id 打开。新建的会话服务端列表还没落盘时，本地拿不到 `Thread`
    /// 对象 —— 以前那种情况整个回调直接 return，表现就是"新会话创建不了"。
    func open(id: String, running: Bool = false) {
        suspendVisibleTranscript()
        resetSession()
        list.currentID = id
        displayedThreadID = id
        list.refreshConfiguration(force: true)
        list.markSeen(id)
        approvals = []
        queued = []
        // 锁是**会话**的属性：切走再回来不该忘（忘了就会拿 turn/start
        // 去撞写者锁）。真正放锁时由 releaseWriterLocks / 发送成功清。
        desktopLocked = desktopLockedThreads.contains(id)
        hasOlder = false
        loadedTurns = Self.firstPage
        loadingOlder = false
        // 签名是"这个会话最新回合长什么样"，跨会话共享会让新会话
        // 因为签名相同而跳过刷新（内容停在旧会话上）。
        lastRemoteSig = ""
        // 还没落进列表的流式增量属于**上一个**会话，直接丢掉。
        // flush 是延迟 55ms 跑的，这期间切会话就会把旧会话的 delta
        // 追加到新会话的消息里（内容串会话）。
        flushTimer?.invalidate()
        flushTimer = nil
        buf.removeAll()
        warmMs = -1
        netMs = -1
        // 上一个会话遗留的"正在跑"状态要清掉。
        // turn/completed 只对当前会话生效（服务端只把事件发给发起方），
        // 所以切走之后那边跑完，busy 会一直卡在 true —— 再点进来就是
        // 三个点一直跳，其实什么都没在跑。用会话自己的状态重置。
        // 用量：服务端只在跑回合时推一次，打开旧会话问不到（见 UsageCache）。
        // 先把上次记下的值摆出来，别让用量页空着说"这个会话还没跑过"。
        restoreUsage(id)
        // 再问常驻的桥接要一次（服务端查不到历史用量，见 UsageFetch）。
        pullUsage(id)

        busy = running
        // **不许把"在跑"清零**。`open` 是从「打开会话」这条路进来的，
        // 而"这个会话在不在跑"只有服务端知道：桌面 Codex 和手机是两个
        // app-server 进程，手机这边 `thread/turns/list` 对别人跑着的回合
        // 报的是 `interrupted`（实测），`thread/list` 报 `notLoaded` ——
        // 两个都不可信。
        // 唯一准的是 `thread/status/changed`（广播事件）。所以进会话时
        // 先按最近一次事件的值走，等事件到了再纠正；本地发起回合时
        // 自己会置 true。
        if let known = list.thread(id)?.running { busy = known }
        // **本机发起的回合还跑着 → busy 不能掉。**
        //
        // `thread/list` 报的是别的进程的视图：手机自己起的回合它报
        // `notLoaded`（实测），于是切回来 `busy` 是 false —— 输入框显示
        // 「发送」，点下去走 `turn/start`，而回合还在跑。用户报的
        // 「切出去再回来插话变成排队/另发一条」里就有这一半。
        if activeTurnIds[id] != nil { busy = true }

        // 1) 后台读磁盘缓存。网络回包先到时，缓存不得覆盖新内容。
        let t0 = Date()
        let openSession = openSeq
        items = []
        restoreVisibleTranscript(id)
        loading = items.isEmpty
        let emptyGeneration = gen
        repository.cachedItems(id) { [weak self] cached in
            guard let self, self.openSeq == openSession, self.list.currentID == id,
                  self.netMs < 0, self.gen == emptyGeneration,
                  self.items.isEmpty, !cached.isEmpty else { return }
            self.items = cached
            self.loading = false
            self.warmMs = Int(Date().timeIntervalSince(t0) * 1000)
        }

        // 2) 再拉网络。
        //
        // **打开会话不 resume。**
        //
        // `thread/resume` 会拿下这个会话的**写者锁**
        // （`~/.codex/thread-writer-locks/<id>.lock`，进程级 flock），
        // 而协议里没有"卸载会话"的方法 —— `thread/unsubscribe` 实测只解订阅、
        // 锁不放，锁只在 app-server 进程退出时由内核释放。
        //
        // 以前 open 就 resume，于是手机上点开过的每个会话都被手机端锁住，
        // 桌面端再打开就弹「已在另一个应用中打开 / 请先在那边关闭会话」。
        // 实测手机端那个 app-server 连跑了 5 小时 18 分一直占着锁，
        // 桌面端干不了活（用户截图）。
        //
        // 只看内容根本不需要锁：`thread/turns/list` 直接就能拉。
        // 锁留到用户真的按发送那一刻再拿（见 `startTurn`）。
        resuming = false
        reload(limit: Self.firstPage)
        loadQueued(id)
        // 无条件开轮询。
        // 以前是 `if running`：但手机端 app-server 对"电脑端正占着写者锁"
        // 的会话，`thread/list` 报的是 `status.type = notLoaded`（实测），
        // 这个条件永远为假 —— 手机端于是从不轮询，界面永远停在
        // 打开会话那一刻的内容上（用户："app 打开他只会卡在刚加载进去的"）。
        startRemoteWatch(id)
    }

    /// 后台预取：把还没有缓存的会话按顺序拉一遍，存进磁盘。
    ///
    /// 为什么需要：服务端取"最新 12 个回合"要**从头扫一遍 rollout 文件**，
    /// 实测一个 194MB 的会话要 11–18 秒（payload 只有 7KB）。客户端改不了
    /// 服务端的实现，但可以提前把它拉好 —— 用户点进去时命中缓存就是秒开。
    ///
    /// 串行 + 一次一个，别把 app-server 打满（它会漏 FD，见 supervise.sh）。
    func prefetch(_ ids: [String]) {
        guard prefetchRunning == nil else { return }
        // **没有缓存的**要拉；**缓存过期的**也要拉。
        //
        // 以前只拉没有缓存的（`!repository.cache.has($0)`），于是缓存写一次之后
        // 永远不刷新：电脑端再跑几个回合，手机这份还是旧的，用户点进去
        // 先看到的就是"以前的聊天记录"。实测缓存能落后 4~40 个回合。
        prefetchGeneration += 1
        let generation = prefetchGeneration
        prefetchRunning = []
        let cache = repository.cache, namespace = repository.cache.namespace
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var seen = Set<String>()
            let todo = ids.filter { seen.insert($0).inserted && cache.isStale($0) }.prefix(40)
            Task { @MainActor in
                guard let self, self.prefetchGeneration == generation,
                      cache.namespace == namespace else { return }
                self.prefetchRunning = Array(todo)
                self.nextPrefetch()
            }
        }
    }

    func nextPrefetch() {
        guard var rest = prefetchRunning, !rest.isEmpty else {
            prefetchRunning = nil
            return
        }
        let id = rest.removeFirst()
        prefetchRunning = rest
        let generation = prefetchGeneration
        // 这里也走 full：预取的目的就是让下次打开能直接看到过程条目，
        // 用 summary 写缓存等于把思考过程和命令输出提前丢掉。
        repository.refreshSnapshot(id, limit: Self.cacheTurns) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.prefetchGeneration == generation else { return }
                // 拉一个歇一下：连着拉大会话会让 app-server 卡住。
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard self.prefetchGeneration == generation else { return }
                self.nextPrefetch()
            }
        }
    }

    func close() {
        suspendVisibleTranscript()
        resetSession()
        list.currentID = nil
        items = []
        approvals = []
        queued = []
    }

    func resetSession() {
        openSeq += 1
        stopRemoteWatch()
        flushTimer?.invalidate()
        flushTimer = nil
        buf.removeAll()
        busy = false
        configurationPreparing = false
        // **这里不碰回合归属。**
        //
        // `serverTurnId` / `localTurn` 是**会话**的属性，不是"看没看着"的。
        // 以前在这里清成 nil / false，于是切出去再回来：
        //   1. `turn/steer` 没有 `expectedTurnId`（必填）→ 只能降级排队；
        //   2. `localTurn=false` 让轮询把手机自己的回合判成"电脑端占着"。
        // 归属现在按 threadId 存在 `activeTurnIds` / `ownedTurnThreads`
        // 里，切会话不动它。真结束了由 `turn/completed`、轮询或
        // `forgetTurn` 清。
        stopRequested = false
        sendingID = nil
        lastTurnId = nil
        displayedThreadID = nil
        streamIsContinuous = false
        turnStarted = nil
        liveAgent = nil; liveReason = nil; liveCmd = nil; livePlan = nil
        pendingSend = nil
        failed.removeAll()
        sendStates.removeAll()
        banner = nil
        previewImage = nil
        usage = nil
        loading = false
        loadingOlder = false
        hasOlder = false
        resuming = false
        lastRemoteSig = ""
        remoteTick = 0
        // **重新开一次会话 = 重新算 priming。**
        //
        // priming 的语义是"打开会话时就已经在那儿的回合不通知"。
        // 它是**会话边界**的属性，所以在这里清，不在 `startRemoteWatch`
        // 里清 —— 那个函数还会被"切后台/回前台/电脑端起了个回合"调用，
        // 每次清一遍就会把要通知的那条回合当成旧回合吃掉（实测：后台
        // 跑完一条回合通知永远不发）。
        remotePrimed = false
        remotePrimedThread = nil
    }

    /// 断线 / 切后台期间漏掉的内容补拉。
    ///
    /// 用户报的现象：「我发完消息切后台，回复完了再切回来，看不见回复」。
    ///
    /// 根因有两条，缺一条都补不上：
    ///   1. SwiftUI 的 `ForEach` 只认 id。服务端给进入会话时那条
    ///      `item/agentMessage/delta` 建的占位 id 从没跟 `thread/turns/list`
    ///      的**真实** item id 对齐过 —— 补拉成功也渲染不出第二段正文。
    ///   2. 没连上 / 后台期间没有任何主动补拉，只靠 `reload()` 那一次。
    ///
    /// 所以这里做两件事：**先对齐 id，再按 id 合并**。
    ///
    /// **不能整体替换**。`thread/turns/list` 不带 `itemsView` 时服务端默认给
    /// `summary` 视图，它会把 `reasoning` / `commandExecution` / `fileChange`
    /// 这类条目**整条丢掉**（实测同一个回合：summary 2 条 1.0KB，
    /// full 6 条 3.3KB）。整体替换等于每次回前台都把屏幕上已有的
    /// 思考过程、命令输出抹掉一遍。
    /// 合并就没这个问题：服务端没给的条目本地原样留着。
    func catchUp() {
        guard let id = list.currentID else { return }
        historyRequestSeq += 1
        let request = historyRequestSeq
        items = Self.alignAgentIds(items, realIds: serverAgentIds())
        let limit = Self.cacheTurns
        let session = openSeq
        let namespace = repository.cache.namespace
        repository.perform(.turns(["threadId": id, "limit": limit,
                                      "sortDirection": "desc", "itemsView": "full"])) { [weak self] r in
            Task { @MainActor in
                guard self?.openSeq == session, self?.list.currentID == id else { return }
                guard let self, self.list.currentID == id else { return }
                guard self.historyRequestSeq == request else { return }
                self.loadingOlder = false
                guard case .success(let v) = r else {
                    self.remoteErr = "补拉失败"
                    return
                }
                parseConversationItemsOffMain(v) { [weak self] fresh in
                    guard let self, self.repository.cache.namespace == namespace,
                          self.openSeq == session, self.list.currentID == id,
                          self.historyRequestSeq == request else { return }
                    self.storeSnapshot(v, threadId: id)
                    if let newest = (v as? JSONDict)?.dicts("data").first {
                        self.reconcileRecoveredTurn(newest, threadID: id)
                    }
                    // `serverTurnId` 为空（`turn/start` 的回包丢了）时**不能**
                    // 当成"不是我的回合" —— 那正是最需要兜底的情况。
                    // 以前这里跟 `pollRemote` 一样会被 nil 挡住，`busy` 和
                    // `localTurn` 双双卡死，用户看到"发出去没反应"。
                    if let newest = (v as? JSONDict)?.dicts("data").first,
                       !Self.isActive(newest),
                       !self.configurationPreparing, self.sendingID == nil || self.localTurn,
                       Self.polledCompletionIsMine(localTurn: self.localTurn,
                           serverTurnId: self.serverTurnId, turnId: newest.str("id"),
                           clientId: self.sendingID ?? self.pendingSend?.id,
                           turnClientId: Self.turnClientId(newest)) {
                        self.busy = false
                        self.forgetTurn(id)
                    }
                    self.mergeTail(Self.withoutShorterAgentText(fresh, than: self.items))
                    self.loading = false
                    let total = self.items.reduce(0) { $0 + ($1.isAgent ? $1.text.count : 0) }
                    self.remoteErr = ""
                    self.remoteStatus = "补拉 \(fresh.count) 条 / 正文 \(total) 字"
                }
            }
        }
    }

    /// 从服务端那一份里剔除「正文比本地还短」的助手条目。
    ///
    /// 服务端回合没落盘完时，`thread/turns/list` 给的正文可能比本地流式
    /// 攒出来的还短。直接用会把界面上正在增长的那条**回退**成旧版本
    /// （用户看到"内容闪一下变短 / 获取不完整"）。
    /// 过程条目（思考/命令/改动）不参与这个判断 —— 它们只有服务端有。
    nonisolated static func withoutShorterAgentText(_ fresh: [Item],
                                                    than local: [Item]) -> [Item] {
        var best: [String: Int] = [:]
        for it in local {
            if case .agent(let id, let t) = it {
                best[id] = max(best[id] ?? 0, t.count)
            }
        }
        return fresh.filter { it in
            guard case .agent(let id, let t) = it else { return true }
            return t.count >= (best[id] ?? 0)
        }
    }

    /// 把末尾那条 id 对不上的助手正文，换成服务端的真实 id。
    ///
    /// 纯函数，方便测。见 `catchUp` 上面那段注释。
    /// 只动**末尾**一条：历史条目在服务端的 turns/list 里都有真实 id，
    /// 出现不匹配说明它们本来就是别的东西，不能乱改。
    nonisolated static func alignAgentIds(_ items: [Item], realIds: [String]) -> [Item] {
        guard let last = realIds.last, !items.isEmpty else { return items }
        var out = items
        let i = out.count - 1
        guard case .agent(_, let t) = out[i], !t.isEmpty else { return out }
        guard !realIds.contains(out[i].id) else { return out }
        out[i] = .agent(id: last, text: t)
        return out
    }

    /// 当前 items 里已有的助手条 id（用来判定 localId 占位）。
    func serverAgentIds() -> [String] {
        items.compactMap { it in
            if case .agent(let id, let t) = it, !t.isEmpty { return id }
            return nil
        }
    }

    func reload(limit: Int = pageSize) {
        guard let id = list.currentID else { return }
        FreezeWatchdog.mark("reload")
        let limit = max(limit, loadedTurns)
        historyRequestSeq += 1
        let request = historyRequestSeq
        let t0 = Date()
        loading = items.isEmpty
        // 必须用 desc：`asc` + limit 拿到的是**最老**的 N 个回合，
        // 会话一长就永远看不到最新内容。desc 拿最新的 N 个，
        // 解析层再反转成正序（Protocol_.items 里做）。
        let session = openSeq
        let namespace = repository.cache.namespace
        var params: JSONDict = ["threadId": id, "limit": limit, "sortDirection": "desc"]
        if busy { params["itemsView"] = "full" }
        repository.perform(.turns(params)) { [weak self] r in
            Task { @MainActor in
                guard self?.openSeq == session, self?.list.currentID == id else { return }
                guard let self else { return }
                // 切走之后旧回包才到：**不能**拿它覆盖当前会话的内容。
                // 以前没有这道校验，快速连点两个会话就会看到"点进去是
                // 上一个会话的消息"。
                guard self.list.currentID == id else { return }
                guard self.historyRequestSeq == request else { return }
                self.loadingOlder = false
                switch r {
                case .success(let v):
                    self.netMs = Int(Date().timeIntervalSince(t0) * 1000)
                    parseConversationItemsOffMain(v) { [weak self] fresh in
                        guard let self, self.repository.cache.namespace == namespace,
                              self.openSeq == session, self.list.currentID == id,
                              self.historyRequestSeq == request else { return }
                        if let newest = (v as? JSONDict)?.dicts("data").first {
                            self.reconcileRecoveredTurn(newest, threadID: id)
                        }
                        // 缓存为空就直接用；否则只在"内容真的变了"时替换，
                        // 避免流式过程中把正在增长的那条冲掉。
                        // 服务端是权威。流式过程中条数没变就别动（会冲掉正在增长
                        // 的那条）；其余情况一律用服务端的，否则回前台会停在旧内容上。
                        // 流式输出中：服务端的回合还没落盘完整，条数相同甚至
                        // 更少时替换会把本地正在增长的那条冲回旧版本 ——
                        // 用户看到的就是"内容闪一下变短 / 获取不完整"。
                        // 只有确实更完整（条数更多）或不在跑时才用服务端的。
                        if self.items.isEmpty {
                            self.items = fresh
                        } else {
                            self.mergeTail(Self.withoutShorterAgentText(fresh,
                                                                        than: self.items))
                        }
                        self.loadedTurns = limit
                        self.hasOlder = Self.hasMoreTurns(v, limit: limit) && limit < 300
                        self.loading = false
                        // **这里不写缓存。**
                        //
                        // reload 拉的是 summary（快），拿它写缓存会把 `saveCache`
                        // 写的 full 那份**降级** —— 过程条目（思考/命令）又没了。
                        // 缓存统一由 `saveCache`（full）维护，打开会话时补一次。
                        self.saveCache()
                    }
                case .failure(let e):
                    self.loading = false
                    self.banner = e.localizedDescription
                }
            }
        }
        // 空白首屏先等 summary 结果；其完成回调再触发一次 full 缓存，
        // 避免打开含图片的会话并发扫两遍同一个大 rollout。
        saveCache()
    }
}

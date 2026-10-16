import Foundation



extension ConversationModel {
    /// app-server 只把 turn/* 事件发给"发起该回合的连接"。
    /// 电脑端发起的回合手机收不到 delta，只能轮询补齐。
    func startRemoteWatch(_ id: String) {
        guard remotePollingAllowed else { return }
        // 目标变了就重建定时器。
        //
        // 以前是 `guard remoteTimer == nil else { return }` —— 定时器闭包里
        // 捕获的是**第一次**那个 id，于是只有第一个打开的会话会被轮询，
        // 之后切过去的会话永远收不到电脑端的更新（用户："电脑发的消息
        // 我手机版看不到"）。实测：open(A) 之后 open(B)，定时器还在轮 A。
        if remoteTimer != nil, remoteWatching == id { return }
        remoteTimer?.invalidate()
        remoteWatchGeneration += 1
        remotePollInFlight = false
        remoteWatching = id
        // 刚打开会话时，最新那个回合可能**早就跑完了**（电脑端几分钟前
        // 干的活）。先把它记成"已见过"，不然一进会话就为一条旧回合
        // 弹通知，正文还因为本地没内容而是空的。
        //
        // **只有"换了一个会话"才重新算 priming。**
        //
        // 以前这里无条件 `remotePrimed = false`。而切后台会
        // `stopRemoteWatch()`（省电，见 enterBackground），电脑端一起回合
        // 又会 `startRemoteWatch()` 把它武装回来 —— 武装的那一刻
        // priming 被清掉，等 20 秒后第一次轮询看到的**正好就是那条要通知
        // 的回合**，于是它被当成"打开会话时就有的旧回合"记账吃掉了：
        // 后台跑完一条回合，通知永远不发（实测 notifyState=fired=-）。
        // 同一个会话重新武装 = 接着看，baseline 不能丢。
        if remotePrimedThread != id {
            remotePrimed = false
            remotePrimedThread = id
        }
        remotePollFast = false
        remoteArms += 1
        let generation = remoteWatchGeneration
        remoteTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIdle, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.remoteWatchGeneration == generation, self.remoteWatching == id else { return }
                self.pollRemote(id)
            }
        }
        // **进会话立刻问一次，别等一个完整间隔。**
        //
        // 定时器第一次触发要等 20 秒（空闲间隔）。这 20 秒里 `busy` 还是
        // `open()` 猜出来的值，而它对"电脑端正在跑的会话"通常是 false
        // （`thread/list` 对别人跑的回合报 `notLoaded`）。于是输入框显示
        // 「发送消息」，点下去走 `turn/start`：
        //   - 会话被电脑端占着 → 回 "active writer"，白等一次往返；
        //   - 本机自己的回合还跑着 → **另起一个回合**，界面上两条一样的
        //     消息（用户报的「一下发两个」）。
        // 用户报的「我切别的会话之后再换回那个会话还是显示排队发送而不是
        // 插话」就是这一段窗口：切回来时轮询刚被重建，第一次查询还没到，
        // 界面按"空闲"渲染。
        //
        // 只加这一次立即查询：之后照旧按间隔走（空闲 20 秒，别白烧电）。
        // 这条查询看到回合在跑会自己 `setPollFast(true)` 切快轮询。
        let armSession = openSeq
        let baseline = remotePolls
        Task { @MainActor [weak self] in
            // 重试几次：`pollRemote` 在 `configurationPreparing` 时会直接返回
            // （一次请求都不发），只在 0.6 秒放一发的话可能正好撞上，
            // 那就又回到"等 20 秒"的老样子。看到轮询真的跑过一次就收手。
            for delay in [0.6, 2.0, 4.0, 8.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.remoteWatchGeneration == generation,
                      self.openSeq == armSession, self.list.currentID == id else { return }
                if self.remotePolls > baseline { return }
                self.pollRemote(id)
            }
        }
    }

    func stopRemoteWatch() {
        remoteTimer?.invalidate()
        remoteTimer = nil
        remoteWatching = nil
        remoteWatchGeneration += 1
        remotePollInFlight = false
        prefetchGeneration += 1
        prefetchRunning = nil
    }

    /// 轮询间隔：没人在跑的时候慢，跑起来再加快。
    ///
    /// 以前固定 2.5 秒，**不管有没有回合在跑** —— 实测会话页放着不动
    /// 60 秒发 29 个 `thread/turns/list`，整机每分钟 ~78 个请求。
    /// 用户报的「太耗电了」主因之一。
    ///
    /// 空闲时该多久拉一次：跨进程的回合手机收不到事件（见文件头注释），
    /// 只能靠轮询发现"电脑端刚起了个新回合"。20 秒的发现延迟可以接受。
    static let pollIdle: TimeInterval = 20
    /// 有回合在跑时的间隔。流式内容要跟得上。
    static let pollBusy: TimeInterval = 2.5

    /// 当前是不是快轮询。慢了之后再拉快要重建定时器。
    func setPollFast(_ fast: Bool) {
        guard remotePollFast != fast, remoteTimer != nil,
              let id = remoteWatching else { return }
        remotePollFast = fast
        remoteTimer?.invalidate()
        let generation = remoteWatchGeneration
        remoteTimer = Timer.scheduledTimer(withTimeInterval: fast ? Self.pollBusy : Self.pollIdle,
                                           repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.remoteWatchGeneration == generation, self.remoteWatching == id else { return }
                self.pollRemote(id)
            }
        }
    }

    func pollRemote(_ id: String) {
        guard remotePollingAllowed, list.currentID == id else { return }
        onPoll?()
        if pendingSend != nil { confirmPending() }
        // 配置同步和历史增量是两条独立链路。历史请求卡住时仍要刷新
        // 老会话的模型/强度，否则电脑端已经换回模型，手机要等历史请求
        // 超时后才更新，用户会一直看到旧模型。
        list.refreshConfiguration()
        guard !remotePollInFlight else { return }
        remotePollInFlight = true
        let generation = remoteWatchGeneration
        FreezeWatchdog.mark("pollRemote")
        // 每 2.5 秒拉一次**完整** turns（40 个回合，大会话几 MB）太重了 ——
        // 电脑端跑长任务时手机就是一直卡。只拉**最新一个回合**（limit 1），
        // 内容变了就换掉本地尾部，不做全量重拉。
        //
        // **必须显式带 itemsView**：默认（summary）会把**进行中**的回合
        // 截断成只剩一条 userMessage（实测 limit=3 时 items=1，full 是 10），
        // 电脑端发的内容在手机上就是"看不见"。full 一个回合约 30KB，
        // 每 2.5 秒拉一次太费流量，所以 summary 为主、每 3 次升一次 full。
        remoteTick += 1
        let pollTick = remoteTick
        var params: JSONDict = ["threadId": id, "limit": 1, "sortDirection": "desc"]
        params["itemsView"] = (remoteTick % 3 == 0) ? "full" : "summary"
        let session = openSeq
        let namespace = repository.cache.namespace
        repository.perform(.turns(params)) {
            [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.remoteWatchGeneration == generation else { return }
                self.remotePollInFlight = false
                guard self.repository.cache.namespace == namespace,
                      self.openSeq == session, self.list.currentID == id else { return }
                if self.configurationPreparing { return }
                self.remotePolls += 1
                guard case .success(let v) = r else {
                    if case .failure(let e) = r { self.remoteErr = e.localizedDescription }
                    return
                }
                guard let turn = (v as? JSONDict)?.dicts("data").first else {
                    self.remoteErr = "没有回合"
                    return
                }
                self.remoteErr = ""
                self.remoteStatus = (turn.str("status")
                    ?? turn.dict("status")?.str("type") ?? "-")
                    + "/" + (turn.str("id")?.suffix(4).description ?? "-")
                // 只认当前会话。以前这里会把**别的会话**的最新回合
                // mergeTail 进当前会话 —— 用户看到的是"内容串了"。
                guard self.list.currentID == id else { return }
                // 轮询看到服务端还在跑 → 界面也得是"在跑"。
                //
                // 电脑端发起的回合，手机端收不到 `turn/started`
                // （只发给发起方），于是 `busy` 一直是 false：
                //   1. 输入框右边显示的是「发送」不是「停止」；
                //   2. 那会儿点下去是**再发一条**，不是停止。
                // 这段必须在 `sig` 那个提前 return **之前**执行 ——
                // 内容没变时 sig 相同会直接返回，放后面就永远够不着。
                // **`serverTurnId` 还没拿到时不能过滤。**
                //
                // 它是 `turn/start` 的回包带回来的。手机在弱网里发消息，
                // 那个回包正好丢在断线窗口里 → `serverTurnId` 永远是 nil →
                // 这一行每次都判成"这不是我发的那个回合" → **整个轮询 return**。
                //
                // 后果是两层：
                //   1. 服务端明明跑完并回复了，手机上永远看不到；
                //   2. 下面那段复位代码在 return 后面，`busy` 永远清不掉。
                // 用户看到的就是「发消息不理我」，而且之后每一条都被送进
                // 排队（`send` 里 `if busy` 那条路），一起石沉大海。
                self.reconcileRecoveredTurn(turn, threadID: id)
                guard Self.polledTurnIsMine(localTurn: self.localTurn,
                                            serverTurnId: self.serverTurnId,
                                            turnId: turn.str("id")) else { return }
                if self.localTurn, self.serverTurnId == nil {
                    guard Self.polledCompletionIsMine(localTurn: true, serverTurnId: nil,
                        turnId: turn.str("id"), clientId: self.sendingID ?? self.pendingSend?.id,
                        turnClientId: Self.turnClientId(turn)) else { return }
                }
                if Self.isActive(turn) {
                    self.remoteActive += 1
                    if !self.busy {
                        self.busy = true
                        self.turnStarted = Date()
                    }
                    // 这个回合是谁发起的？
                    //
                    // **不能只看 `localTurn`。** 切出去再回来时 `localTurn`
                    // 是 false（那是"当前会话"的状态，不是归属），于是
                    // 手机自己起的回合被当成电脑端的 —— `desktopLocked`
                    // 置上之后插话永远降级成排队。用户报的正是这个：
                    // 「一直在一个会话里插话能用，我一切出去就变成排队了」。
                    //
                    // 先按 `clientUserMessageId` 认领：`turn/start` /
                    // `turn/steer` / `thread/queue/add` 都带它，服务端原样
                    // 回显（实测）。认出来是我们发的 → 归属本机，别标锁。
                    let clientId = Self.turnClientId(turn)
                    if self.ownsTurn(clientID: clientId) {
                        self.ownedTurnThreads.insert(id)
                        self.desktopLocked = false
                    } else if !self.localTurn {
                        // 真不是我们的 → 它在**电脑端的进程**里跑，那个进程
                        // 持有这个会话的写者锁。记下来，发送时先探锁
                        // （`startTurn` 里那条 `desktopLocked` 分支），插话
                        // 则直接进共享队列 —— 实测：不记这一笔，插话会先
                        // 失败一次（`thread not found`），用户白等一轮。
                        self.desktopLocked = true
                    }
                    if let t = turn.str("id") {
                        self.serverTurnId = t
                        self.lastTurnId = t
                    }
                    // 在跑 → 切快轮询，流式内容才跟得上。
                } else if self.busy, !self.localTurn {
                    self.busy = false
                    self.forgetTurn(id)
                } else if !Self.isActive(turn), self.localTurn {
                    guard Self.polledCompletionIsMine(localTurn: self.localTurn,
                                                      serverTurnId: self.serverTurnId,
                                                      turnId: turn.str("id"),
                                                      clientId: self.sendingID ?? self.pendingSend?.id,
                                                      turnClientId: Self.turnClientId(turn)) else { return }
                    // 本地发起的回合，服务端已经跑完了。
                    // 本地攒的正文是流式增量拼的，跟服务端落盘的那一份
                    // 可能差一截（用户："回答完了我再回 app 看不见回复内容"）。
                    // 这里补一次，用服务端的完整版本覆盖。
                    self.forgetTurn(id)
                    // **`busy` 必须一起复位。**
                    //
                    // 以前只清 `localTurn`，指望 `turn/completed` 事件来清
                    // `busy`。而弱网下丢的往往正是那条事件 —— 于是 `busy`
                    // 永远停在 true：输入框一直显示「停止」，用户再发消息
                    // 全被 `send` 送进排队。轮询是唯一可靠的兜底，就得兜到底。
                    self.busy = false
                    self.turnStarted = nil
                    self.catchUp()
                }
                self.setPollFast(Self.isActive(turn))
                let pollSession = self.openSeq
                parseConversationItemsOffMain(["data": [turn]]) { [weak self] tail in
                    guard let self, self.repository.cache.namespace == namespace,
                          self.openSeq == pollSession,
                          self.list.currentID == id,
                          self.remoteWatchGeneration == generation,
                          self.remoteTick == pollTick else { return }
                    guard !tail.isEmpty else { return }
                    var hasher = Hasher()
                    for item in tail { hasher.combine(item) }
                    let sig = "\(hasher.finalize())"
                    guard sig != self.lastRemoteSig else { return }
                    self.lastRemoteSig = sig
                    self.mergeTail(tail)
                    // 电脑端发起的回合跑完了 —— 顺手补一条通知。
                    // 解析结果复用，避免图片/长正文在主线程再扫一遍。
                    self.notifyIfTurnFinished(turn, parsed: tail)
                }
            }
        }
    }

    /// 轮询 / 补拉拿到的这个回合，能不能当成"我们本地发起的那个"来处理。
    ///
    /// **`serverTurnId` 为空时必须返回 true（不能排除）。**
    ///
    /// 它是 `turn/start` 回包带回来的。手机在弱网里发消息，那个回包正好丢在
    /// 断线窗口里 → `serverTurnId` 永远是 nil → 以前这里每次都判成"这不是我
    /// 发的那回合" → **整个轮询直接 return**：
    ///   1. 服务端明明跑完并回复了，手机上永远看不到；
    ///   2. 复位代码在 return 后面，`busy` / `localTurn` 永远清不掉。
    /// 用户看到的就是「发消息不理我」，而且之后每条消息都被 `send` 里的
    /// `if busy` 送进排队，一起石沉大海。
    ///
    /// 判断不了就**当成自己的**：`mergeTail` 是幂等的（按 id 认领、就地更新），
    /// 多合并一次没有任何副作用，把用户晾在那儿才是真的错。
    nonisolated static func polledTurnIsMine(localTurn: Bool, serverTurnId: String?,
                                             turnId: String?) -> Bool {
        guard localTurn, let sid = serverTurnId else { return true }
        return turnId == sid
    }

    nonisolated static func turnClientId(_ turn: JSONDict) -> String? {
        for item in turn.dicts("items") where item.str("type") == "userMessage" {
            if let id = item.str("clientUserMessageId") ?? item.str("clientId"), !id.isEmpty { return id }
        }
        return turn.str("clientUserMessageId") ?? turn.str("clientId")
    }

    nonisolated static func polledCompletionIsMine(localTurn: Bool, serverTurnId: String?,
                                                    turnId: String?, clientId: String?,
                                                    turnClientId: String?) -> Bool {
        guard localTurn else { return true }
        if let serverTurnId { return turnId == serverTurnId }
        guard let clientId, let turnClientId else { return false }
        return clientId == turnClientId
    }

    /// 打开会话时把**上次记下的**用量摆出来。
    ///
    /// 单独抽出来是为了能测：服务端没有查历史用量的方法
    /// （实测 thread/read / turns/list / resume 都拿不到），
    /// 只能靠本地记。漏了这一步，用量页就永远是空的。
    func restoreUsage(_ id: String) {
        usage = UsageCache.load(id)?.usage
    }

    /// 再问**桥接**要一次（服务端查不到历史用量，见 `UsageFetch`）。
    ///
    /// 只在本地一份都没有时填：本地那份是这一轮事件真收到的，不比桥接旧。
    /// 必须校验 `currentID` —— 这个请求是异步的，用户可能已经切走了。
    func pullUsage(_ id: String) {
        let session = openSeq
        Task { @MainActor in
            guard let u = await UsageFetch.load(settings, id) else { return }
            guard openSeq == session, list.currentID == id, usage == nil else { return }
            usage = u
            UsageCache.save(id, u)
        }
    }

    /// 这个回合是不是刚跑完（轮询看到的），是就补一条通知。
    ///
    /// 只在**电脑端发起**的回合上用：手机自己发起的回合走事件流，
    /// `turn/completed` 那条路已经在 AppCoordinator 里处理了。
    func notifyIfTurnFinished(_ turn: JSONDict, parsed: [Item]? = nil) {
        guard let tid = turn.str("threadId") ?? list.currentID else { return }
        // 手机自己发起的：事件流负责，这里别插一脚，否则一条回合两条通知。
        if localTurn { return }
        let key = turn.str("id") ?? ""
        guard !key.isEmpty else { return }
        let text = (parsed ?? Protocol_.items(fromTurn: turn)).filter { $0.isAgent }
            .map { $0.text }.joined(separator: "\n")
        Notifier.trace.append("k=\(key.suffix(4)) ag=\(text.count) p=\(remotePrimed ? 1 : 0)")
        // 第一次看到的是"打开会话时已有的那条"，只记账不通知。
        guard remotePrimed else {
            remotePrimed = true
            remotePrimedThread = tid
            lastNotifiedTurn = key
            Notifier.markFired(key)
            return
        }
        // 双重去重：本会话内 (`lastNotifiedTurn`) + 全局已通知过的回合。
        // 后者是必要的 —— 换会话 / 重进会话会把 `lastNotifiedTurn` 重置，
        // 同一个回合于是又响一次（通知要振动亮屏，重复响很耗电）。
        guard key != lastNotifiedTurn, !Notifier.alreadyFired(key) else { return }
        // **不看 turn.status**：跨进程时服务端对这个回合报的状态可能是
        // `interrupted`（线程没被本进程加载），按状态判定会漏掉通知。
        // 真正可靠的信号是"内容变了、而且有正文"。
        //
        // 正文为空也**不发**：一条"XX 已完成"的空通知比不通知更糟
        // （用户原话："40 次已完成 · Xm 没内容"）。空着就等下一轮 ——
        // 轮询每 3 次升一次 `itemsView: full`，summary 截断掉的内容会补上。
        guard !text.isEmpty else { return }
        lastNotifiedTurn = key
        Notifier.markFired(key)
        let name = list.thread(tid)?.displayTitle ?? "Codex"
        Notifier.turnDone(threadId: tid, title: name, text: text)
    }
    /// 回退：把会话历史退回到某一轮**之前**。
    ///
    /// `thread/revert` 只改持久化的对话历史，**不动磁盘上的文件**
    /// （schema 原话：does not revert local file changes）。
    func revert(beforeTurnId: String) {
        repository.perform(.revert(["threadId": list.currentID ?? "",
                                  "beforeTurnId": beforeTurnId])) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                if case .failure(let e) = r { self.banner = "回退失败：" + e.localizedDescription }
                else { self.reload() }
            }
        }
    }

    /// 回退最近一轮。
    func revertLast() {
        guard let t = lastTurnId else { banner = "没有可回退的回合"; return }
        revert(beforeTurnId: t)
    }

    /// 把一条问题答案发回去。
    func answer(_ q: Question, option: Question.Option?) {
        let text = option.map { $0.label } ?? ""
        guard !text.isEmpty, !configurationPreparing else { return }
        // 运行中回答选项与输入框插话一致，不能走 send 的忙碌排队分支。
        if busy { steer(text) }
        else { send(text) }
    }

}

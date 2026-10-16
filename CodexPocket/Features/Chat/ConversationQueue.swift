import Foundation

// Shared submission queue.

extension ConversationModel {
    /// 把一条消息写进**服务端共享队列**。
    ///
    /// 为什么不是本地排队：实测（两个 app-server 实例，一个持有写者锁）
    /// `thread/queue/add` 在**不持有锁**的连接上也能成功，队列存在
    /// `~/.codex/queue_1.sqlite` 里，两个实例都读得到，持有锁那边跑完
    /// 当前回合就会把它执行掉 —— 会话历史里真的多出这一轮。
    /// 只在已知有运行中的回合时排队；仅有写者锁不代表有回合在运行。
    /// 标签保持 `text:` —— 改标签等于让所有调用点改名，而这里只需要
    /// 在内部清洗。排队也是写 rollout，同样得挡住 U+2028（见 `cleanText`）。
    func enqueueRemote(threadId: String, text rawText: String, images: [String],
                       localId: String) {
        let text = Self.cleanText(rawText)
        guard !acceptedSubmissionIDs.contains(localId) else { return }
        activeSubmissionIDs.insert(localId)
        if lastSendWhy == "-" { lastSendWhy = "排队(调用方)" }
        // 每次提交都是独立消息，只有用户点取消时才删除已有排队。
        var input: [JSONDict] = []
        if !text.isEmpty { input.append(["type": "text", "text": text]) }
        input.append(contentsOf: Self.imageInput(images))
        let session = openSeq
        let namespace = repository.cache.namespace
        repository.perform(.queueAdd(["threadId": threadId,
                                     "clientUserMessageId": localId,
                                     "input": input])) { [weak self] r in
            Task { @MainActor in
                guard let self else { return }
                guard self.repository.cache.namespace == namespace else { return }
                if case .success = r { self.accept(localId) }
                if case .failure(let error) = r,
                   [-32600, -32601, -32602, -32092, -32093].contains((error as NSError).code) {
                    self.fail(localId, "排队失败，请重试")
                    return
                }
                guard case .success = r else {
                    if self.openSeq == session, self.list.currentID == threadId {
                        self.pendingSend = (localId, text)
                        self.markConfirming(localId)
                    }
                    self.confirmSubmission(threadId: threadId, localId: localId, text: text, images: images)
                    return
                }
                guard self.openSeq == session, self.list.currentID == threadId else { return }
                // 排队**立刻**标出来（这条确实要等），但用消息自己的状态行，
                // 不用全局 banner —— banner 会把整屏提示压出来，
                // 而排队是常态操作，不是异常。
                self.markQueued(localId)
                self.loadQueued(threadId)
                self.startRemoteWatch(threadId)
                // **排队不是终点，得有人收尾。**
                //
                // 服务端的共享队列只在"这个会话有回合在跑"时才会被执行。
                // 没人跑的时候写进去就永远躺着（实测：写进队列 30 秒，
                // 回合数一直是 0）。而界面已经把这条消息当成"已送达"了 ——
                // 用户看到的就是"消息发出去没反应"，再发一次就成了两条。
                // 8 秒后对一次账：队列空、也没在跑、服务端又没这条 → 标红让用户重试。
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    self.reconcileQueued(threadId: threadId, text: text,
                                         localId: localId, session: session, tries: 0)
                }
            }
        }
    }

    /// 排队消息的对账：服务端到底执行了没有。
    ///
    /// **`busy` 为真时要重试，不能直接放弃。**
    ///
    /// 原来这里是 `guard !busy else { return }` —— 而 `busy` 卡住（弱网下
    /// `turn/completed` 丢了）正是需要这次对账的时候，于是它一次都不跑，
    /// 排队那条消息就永远躺在服务端队列里：界面显示"排队中"，实际永不执行。
    /// 用户看到的就是「发消息不理我」。
    ///
    /// 现在最多等 6 轮（48 秒）。`pollRemote` 每 20 秒会按服务端状态复位
    /// `busy`，所以正常情况下第二轮就能真正对账。
    func reconcileQueued(threadId: String, text: String, localId: String,
                         session: Int, tries: Int) {
        guard openSeq == session, list.currentID == threadId else { return }
        guard items.contains(where: { $0.id == localId }) else { return }
        if busy, tries < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.reconcileQueued(threadId: threadId, text: text,
                                      localId: localId, session: session,
                                      tries: tries + 1)
            }
            return
        }
        // After the bounded wait, still query the server. A missed
        // turn/completed event can leave `busy` stale; returning here made a
        // queued message permanently unaccounted for.
        repository.perform(.queueList(["threadId": threadId])) { [weak self] result in
            Task { @MainActor in
                guard let self, self.openSeq == session, self.list.currentID == threadId,
                      self.sendStates[localId]?.isQueued == true,
                      case .success(let value) = result,
                      let rows = (value as? JSONDict)?.dicts("data") else { return }
                let waiting = rows.contains {
                    $0.str("clientUserMessageId") == localId
                }
                guard !waiting else {
                    self.loadQueued(threadId)
                    return
                }
                self.confirmDequeued(threadId: threadId, text: text, localId: localId, session: session)
            }
        }
    }

    private func confirmDequeued(threadId: String, text: String, localId: String, session: Int) {
        repository.perform(.turns(["threadId": threadId, "limit": 4,
                                        "sortDirection": "desc",
                                        "itemsView": "full"])) { [weak self] r in
            Task { @MainActor in
                guard let self, self.openSeq == session,
                      self.list.currentID == threadId else { return }
                guard self.items.contains(where: { $0.id == localId }) else { return }
                guard case .success(let v) = r else { return }
                // 服务端有这条了 —— 排队其实执行了，撤掉本地那条。
                var images: [String] = []
                if case .user(_, _, let paths)? = self.items.first(where: { $0.id == localId }) { images = paths }
                if self.containsSubmission(v, localId: localId, text: text, images: images) {
                    self.items.removeAll { $0.id == localId }
                    self.loadQueued(threadId)
                    self.sendStates.removeValue(forKey: localId)
                    self.lastSendWhy = "排队已执行"
                    self.reload(limit: Self.firstPage)
                    return
                }
                self.lastSendWhy = "队列已变化，等待历史确认"
                self.pendingSend = (localId, text)
                self.markConfirming(localId)
            }
        }
    }

    func loadQueued(_ id: String) {
        let session = openSeq
        repository.perform(.queueList(["threadId": id])) { [weak self] r in
            Task { @MainActor in
                guard self?.openSeq == session, self?.list.currentID == id else { return }
                guard let self, case .success(let v) = r else { return }
                // 队列属于那个会话，切走后别再写进当前会话的队列区。
                guard self.list.currentID == id else { return }
                let rows = (v as? JSONDict)?.dicts("data") ?? []
                self.queued = rows.compactMap { q in
                    guard let qid = q.str("id") else { return nil }
                    // 服务端给的是 {id, input:[{type:"text", text:"…"}]}，
                    // 以前读的是顶层 `text` —— 永远拿到 nil，队列条目全是空的。
                    let text = (q.dicts("input") ?? [])
                        .compactMap { $0.str("text") }.joined()
                    return Queued(id: qid, text: text, clientID: q.str("clientUserMessageId"))
                }
            }
        }
    }

    func cancelQueued(_ q: Queued) {
        guard let id = list.currentID else { return }
        // 字段名是 `queuedSubmissionId`。写 `queueId` 服务端会回
        // "missing field `queuedSubmissionId`"，取消永远不生效。
        let session = openSeq
        repository.perform(.queueDelete(["threadId": id, "queuedSubmissionId": q.id])) { [weak self] result in
            Task { @MainActor in
                guard let self, self.openSeq == session, self.list.currentID == id else { return }
                if case .failure = result {
                    self.banner = "取消失败，消息仍在队列中，请重试"
                    return
                }
                self.queued.removeAll { $0.id == q.id }
                if let local = q.clientID {
                    self.items.removeAll { $0.id == local }
                    self.sendStates.removeValue(forKey: local)
                    self.failed.remove(local)
                }
            }
        }
    }

    /// 立刻执行队列里第一条。
    ///
    /// 服务端要求**本连接先 resume 过这个会话**，否则回
    /// "resume the thread before starting a queued message"。
    /// 电脑端占着锁时它必然失败，所以界面上只在没被占用时给这个按钮。
    func runQueuedNow() {
        guard let id = list.currentID else { return }
        let session = openSeq
        repository.perform(.queueStart(["threadId": id])) { [weak self] r in
            Task { @MainActor in
                guard self?.openSeq == session, self?.list.currentID == id else { return }
                guard let self, case .failure(let e) = r else { return }
                self.banner = "现在不能执行：" + e.localizedDescription
            }
        }
    }
}

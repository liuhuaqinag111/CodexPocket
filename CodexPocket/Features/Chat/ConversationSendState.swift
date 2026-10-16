import Foundation

/// 一条本地消息的发送状态：发送中 / 排队 / 失败可重试。
///
/// 从 ConversationSending 拆出来 —— 那边只负责把回合发出去，
/// 这里只管这条消息现在算什么状态，两件事的改动理由不一样。
extension ConversationModel {
    func cancelSubmissionIfRequested(threadId: String, localId: String) -> Bool {
        guard cancelledSubmissionIDs.remove(localId) != nil else { return false }
        if activeTurnIds[threadId] == nil { ownedTurnThreads.remove(threadId) }
        if list.currentID == threadId, sendingID == localId {
            configurationPreparing = false
            stopRequested = false
            sendingID = nil
            busy = false
        }
        fail(localId, "已取消发送")
        return true
    }

    func restoreSubmission(threadID: String, localID: String, text: String, images: [String]) {
        guard list.currentID == threadID else { return }
        activeSubmissionIDs.insert(localID)
        if !items.contains(where: { $0.id == localID }) {
            items.append(.user(id: localID, text: text, images: images))
        }
        pendingSend = (localID, text)
        markSending(localID)
        confirmPending()
    }

    /// 把一条本地消息标成发送失败（渲染成红色 + 重试）。
    func markSending(_ localId: String, since: Date = Date()) {
        onSubmissionStarted?(localId)
        uncertainSubmissionIDs.remove(localId)
        sendStates[localId] = .sending(since: since)
        failed.remove(localId)
        tick += 1
    }

    func markConfirming(_ localId: String) {
        sendStates[localId] = .confirming
        failed.remove(localId)
    }

    func fail(_ localId: String, _ why: String = "连接中断") {
        cancelledSubmissionIDs.remove(localId)
        uncertainSubmissionIDs.remove(localId)
        guard !acceptedSubmissionIDs.contains(localId) else { return }
        activeSubmissionIDs.remove(localId)
        if pendingSend?.id == localId { pendingSend = nil }
        onSubmissionResolved?(localId, false)
        guard items.contains(where: { $0.id == localId }) else { return }
        sendStates[localId] = .failed(why)
        failed.insert(localId)
        tick += 1
        Haptics.error()
    }

    /// 服务端接受了：撤掉状态行。
    func accept(_ localId: String) {
        uncertainSubmissionIDs.remove(localId)
        let first = !acceptedSubmissionIDs.contains(localId)
        activeSubmissionIDs.remove(localId)
        if acceptedSubmissionIDs.count >= 512 { acceptedSubmissionIDs.removeAll() }
        acceptedSubmissionIDs.insert(localId)
        if pendingSend?.id == localId { pendingSend = nil }
        sendStates.removeValue(forKey: localId)
        failed.remove(localId)
        tick += 1
        if first { onSubmissionResolved?(localId, true) }
        Haptics.success()
    }

    /// 进了服务端共享队列。
    func markQueued(_ localId: String) {
        sendStates[localId] = .queued(since: Date())
        tick += 1
    }

    /// 重发一条失败的消息。
    ///
    /// **必须复用原来那条气泡**，不能再 append 一条 —— 用户点了几次重试
    /// 就会看到几条一模一样的消息（报过的 bug）。这里只把原条目从失败
    /// 集合里摘掉、就地把 turn 重跑一遍。
    ///
    /// 图片也要跟着重发：以前这里写死 `images: []`，一条带图的失败消息
    /// 点重试会变成纯文字（图悄悄丢了）。
    func retry(_ localId: String, text: String, images: [String] = [], queue: Bool = false) {
        guard !configurationPreparing else { return }
        guard let id = list.currentID, !text.isEmpty || !images.isEmpty else { return }
        guard failed.contains(localId) else { return }
        guard !activeSubmissionIDs.contains(localId), !acceptedSubmissionIDs.contains(localId) else { return }
        if !queue, busy || canStop {
            steer(text, images: images, localID: localId)
            return
        }
        if queue, busy || canStop {
            if !items.contains(where: { $0.id == localId }) {
                items.append(.user(id: localId, text: text, images: images))
            }
            markSending(localId)
            enqueueRemote(threadId: id, text: text, images: images, localId: localId)
            return
        }
        send(text, images: images, localID: localId)
    }

    /// 服务端回显的这条用户消息，认领掉本地那条乐观插入的气泡。
    ///
    /// 认领顺序：
    ///   1. `clientId` **精确匹配** —— turn/start、turn/steer、queue/add 都
    ///      带上了 `clientUserMessageId`，服务端原样回显（实测）。
    /// 没有 clientId 的回包保持独立，不用相同文本猜测提交身份。
    ///
    /// 认领成功就**就地替换**，认不出来才 append。
    ///
    /// 为什么非要有这一步：`item/completed` 会把服务端那份用户消息当新条目
    /// append 进来，而本地那条乐观插入的气泡还挂着 —— 界面上就是
    /// **两条一模一样的消息**（用户报过两次）。服务端那边其实只有一条。
    @discardableResult
    func adoptServerUser(_ raw: JSONDict, _ fresh: Item) -> Bool {
        guard case .user = fresh else { return false }
        let client = raw.str("clientId") ?? raw.str("clientUserMessageId")
        guard let client, !client.isEmpty else { return false }
        guard let i = items.firstIndex(where: { $0.id == client || $0.id == fresh.id }) else { return false }
        items[i] = fresh
        accept(client)
        if pendingSend?.id == client { pendingSend = nil }
        return true
    }
}

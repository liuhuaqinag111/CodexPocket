import Foundation

@MainActor
final class SuspendedTranscript {
    let items: [Item]
    let lastTurnId: String?
    let started: Date?
    let liveIDs: [String?]
    var continuous: Bool
    let epoch: Int
    var events: [(String, JSONDict)] = []
    private var eventBytes = 0
    private var overflowed = false

    init(_ chat: ConversationModel) {
        items = chat.items
        lastTurnId = chat.lastTurnId
        started = chat.turnStarted
        liveIDs = [chat.liveAgent, chat.liveReason, chat.liveCmd, chat.livePlan]
        continuous = chat.streamIsContinuous
        epoch = chat.streamEpoch
    }

    func append(_ method: String, _ params: JSONDict) {
        guard !overflowed else { return }
        guard method.hasPrefix("item/") || method.hasPrefix("turn/")
                || ["thread/tokenUsage/updated", "thread/plan/updated", "thread/queue/changed",
                    "thread/closed", "thread/reverted", "thread/status/changed",
                    "thread/name/updated"].contains(method) else { return }
        eventBytes += Self.size(params) + method.utf8.count
        guard events.count < 256, eventBytes <= 2 * 1024 * 1024 else {
            events.removeAll()
            continuous = false
            overflowed = true
            return
        }
        if method.lowercased().hasSuffix("delta"), let last = events.last,
           last.0 == method, last.1.str("itemId") == params.str("itemId"),
           let before = last.1.str("delta"), let delta = params.str("delta") {
            var combined = last.1
            combined["delta"] = before + delta
            events[events.count - 1] = (method, combined)
        } else { events.append((method, params)) }
    }

    private static func size(_ value: Any) -> Int {
        if let text = value as? String { return text.utf8.count }
        if let object = value as? JSONDict {
            return object.reduce(0) { $0 + $1.key.utf8.count + size($1.value) }
        }
        if let array = value as? [Any] { return array.reduce(0) { $0 + size($1) } }
        return 16
    }
}



extension ConversationModel {
    func suspendVisibleTranscript() {
        flush()
        guard let id = displayedThreadID ?? list.currentID,
              busy || activeTurnIds[id] != nil else { return }
        suspendedTranscripts.setObject(SuspendedTranscript(self), forKey: id as NSString)
    }

    func restoreVisibleTranscript(_ id: String) {
        lastTurnId = busy ? serverTurnId : nil
        guard let saved = suspendedTranscripts.object(forKey: id as NSString) else { return }
        suspendedTranscripts.removeObject(forKey: id as NSString)
        items = saved.items
        lastTurnId = serverTurnId ?? saved.lastTurnId
        turnStarted = saved.started
        liveAgent = saved.liveIDs[0]; liveReason = saved.liveIDs[1]
        liveCmd = saved.liveIDs[2]; livePlan = saved.liveIDs[3]
        streamIsContinuous = saved.continuous && saved.epoch == streamEpoch
        for (method, params) in saved.events { apply(method, params) }
        if saved.epoch != streamEpoch { streamIsContinuous = false }
        flush()
    }

    func invalidateStreamContinuity() {
        streamEpoch += 1
        streamIsContinuous = false
    }

    private static let snapshotWrites = DispatchQueue(label: "CodexPocket.SnapshotWrites", qos: .utility)

    func storeSnapshot(_ payload: Any, threadId: String) {
        lastCacheAt[threadId] = Date()
        let cache = repository.cache, namespace = repository.cache.namespace
        let limit = Self.cacheTurns
        Self.snapshotWrites.async {
            guard let root = payload as? JSONDict else { return }
            var snapshot = root
            // Responses use desc order; keep the latest full turns only.
            snapshot["data"] = Array(root.dicts("data").prefix(limit))
            guard JSONSerialization.isValidJSONObject(snapshot),
                  let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
            _ = cache.save(threadId, data, namespace: namespace)
        }
    }
    /// 存"当前显示的这些条目"对应的原始回包。
    /// 存不了（比如刚本地插入还没回服务端）就跳过，下次 reload 会补上。
    func saveCache() {
        guard let id = list.currentID, !localTurn, !configurationPreparing,
              !cacheRefreshInFlight.contains(id),
              // 打开空会话时 summary reload 还没回来；同时发 full 快照会让
              // 服务端做两次昂贵扫描，图片会话尤其明显。reload 的解析完成后
              // 会再调用一次，这里只挡住这段窗口。
              !(loading && items.isEmpty) else { return }
        // 节流：一次全量拉取不小，别每轮都拉（send 之后内容根本没变）。
        let now = Date()
        if let t = lastCacheAt[id], now.timeIntervalSince(t) <= 8 { return }
        lastCacheAt[id] = now
        cacheRefreshInFlight.insert(id)
        let session = openSeq
        // **必须带 itemsView: full**。
        //
        // 默认的 summary 视图会把 `reasoning` / `commandExecution` /
        // `fileChange` 整条丢掉（实测同一个回合：summary 2 条 1.0KB，
        // full 6 条 3.3KB）。缓存用 summary 写，就等于**历史回合的过程
        // 从来没被存下来过** —— 用户报的「每次刷新都在丢思考过程和命令输出」
        // 有一半是这里造成的（另一半是刷新时整体替换，已修）。
        //
        // 只取最近几轮：full 比 summary 大 4~28 倍（实测最坏 322KB → 1.3MB），
        // 缓存整个 40 轮会让磁盘和写入时间都失控。
        repository.refreshSnapshot(id, limit: Self.cacheTurns) { [weak self] r in
            // 顺手把这份 full 并进界面。
            //
            // 一趟请求办两件事：写缓存 + 把过程条目补到屏幕上。
            // `reload()` 走的是 summary（快），它永远补不出思考过程和命令
            // 输出；这里用 full 的那一份补，用户就看到内容回来了。
            // 有 8 秒节流兜着，不会变成每轮都拉。
            Task { @MainActor in
                guard let self else { return }
                self.cacheRefreshInFlight.remove(id)
                guard self.lastCacheAt[id] == now else { return }
                guard case .success(let items) = r else {
                    self.lastCacheAt[id] = nil
                    return
                }
                guard self.openSeq == session, self.list.currentID == id else { return }
                self.mergeTail(items)
            }
        }
    }
}

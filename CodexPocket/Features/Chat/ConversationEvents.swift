import Foundation

/// 服务端事件 → 界面状态。
///
/// 视图层不解析协议：`item/*`、`turn/*`、`thread/*` 全部在这里翻译。
/// 协议改版只动这一个文件。
// MARK: - 流式缓冲与事件归约

extension ConversationModel {
    /// 服务端通知统一入口。视图层不解析协议，只改这里。
    func apply(_ method: String, _ p: JSONDict) {
        // 桥接常驻上游的连通性变化：不关 socket，但需要重新装载。
        if method == "bridge/upstream" {
            if (p["connected"] as? Bool) == false { invalidateStreamContinuity() }
            if (p["connected"] as? Bool) == true, let id = list.currentID { reload() ; _ = id }
            return
        }
        // 帧级日志：先记"帧到了"，再记"门放行还是丢"。
        // delta 按条数抽样（见 FrameLog.markDelta），不然 256KB 两分钟就满。
        let iid = p.str("itemId") ?? "-"
        let isDelta = method.hasSuffix("delta")
        if isDelta { FrameLog.markDelta(method, iid) }
        else { FrameLog.mark("FRAME", "\(method) \(iid)") }

        let tid = p.str("threadId") ?? p.dict("turn")?.str("threadId")
        if let tid, tid != list.currentID,
           let saved = suspendedTranscripts.object(forKey: tid as NSString) {
            saved.append(method, p)
            return
        }
        guard let cur = list.currentID else {
            FrameLog.mark("GATE", "丢 \(method)：没有当前会话")
            return
        }
        if method.hasPrefix("item/") || method.hasPrefix("turn/") || method.hasPrefix("thread/") {
            guard tid == cur else { return }
        }
        if let tid, tid != cur {
            FrameLog.mark("GATE", "丢 \(method)：threadId=\(tid.prefix(8)) 不是当前会话")
            return
        }
        if !isDelta { FrameLog.mark("GATE", "放行 \(method)") }

        switch method {
        case "item/agentMessage/delta":
            guard let id = p.str("itemId"), let d = p.str("delta") else { return }
            liveAgent = id
            if !items.contains(where: { $0.id == id }) {
                items.append(.agent(id: id, text: ""))
            }
            buf[id, default: ""] += d
            scheduleFlush()

        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            guard let id = p.str("itemId"), let d = p.str("delta") else { return }
            liveReason = id
            if !items.contains(where: { $0.id == id }) {
                items.append(.reasoning(id: id, text: ""))
            }
            buf["r:" + id, default: ""] += d
            scheduleFlush()

        case "item/commandExecution/outputDelta":
            guard let id = p.str("itemId"), let d = p.str("delta") else { return }
            liveCmd = id
            if !items.contains(where: { $0.id == id }) {
                items.append(.command(id: id, command: "", output: ""))
            }
            buf["c:" + id, default: ""] += d
            scheduleFlush()

        case "item/started":
            guard let it = p.dict("item"), let id = it.str("id") else { return }
            let type = it.str("type") ?? ""
            if type == "userMessage" {
                // 服务端认下这条了：把本地那条乐观插入的气泡**换成**服务端的
                // 版本（按 clientId 精确认领）。不认领的话后面 `item/completed`
                // 会把同一句话再 append 一遍 —— 界面上两条一样的。
                if let one = Protocol_.item(from: it) { _ = adoptServerUser(it, one) }
            } else if type == "reasoning" {
                liveReason = id
                if !items.contains(where: { $0.id == id }) {
                    items.append(.reasoning(id: id, text: ""))
                    tick += 1
                }
            } else if type == "commandExecution" {
                liveCmd = id
                if !items.contains(where: { $0.id == id }) {
                    items.append(.command(id: id, command: it.str("command") ?? "", output: ""))
                    tick += 1
                }
            } else if type == "mcpToolCall" {
                if !items.contains(where: { $0.id == id }), let one = Protocol_.item(from: it) {
                    items.append(one)
                    tick += 1
                }
            }

        case "turn/started":
            streamIsContinuous = true
            busy = true
            turnStarted = Date()
            let tid = p.dict("turn")?.str("id") ?? UUID().uuidString
            lastTurnId = tid
            // 我们收到了这个回合的 started，说明它是在**本连接**发起的
            // （服务端只把事件发给发起方）→ 归属本机，别让它被当成
            // 电脑端的回合而降级成排队。
            if let owner = p.str("threadId") ?? list.currentID {
                ownedTurnThreads.insert(owner)
            }
            // 服务端**只认**自己那个 turn id：`turn/interrupt` 带错会回
            // "expected active turn id X but found Y"（实测）。
            // 本地造的 UUID 停不掉任何东西，所以只记服务端给的真 id。
            if p.dict("turn")?.str("id") != nil { serverTurnId = tid }
            if !items.contains(where: { $0.id == "tb-\(tid)" }) {
                items.append(.turnBreak(id: "tb-\(tid)", at: Date(), duration: nil))
                tick += 1
            }

        case "turn/completed":
            if let completed = p.dict("turn")?.str("id") {
                if completedTurnIDs.count >= 512 { completedTurnIDs.removeAll() }
                completedTurnIDs.insert(completed)
            }
            if let id = p.dict("turn")?.str("id"),
               let active = serverTurnId, active != id { return }
            streamIsContinuous = false
            flush()
            busy = false
            stopRequested = false
            sendingID = nil
            // 归属按会话清 —— 事件里的 threadId 一定是这个回合的会话。
            forgetTurn(p.str("threadId") ?? cur)
            liveAgent = nil; liveReason = nil; liveCmd = nil; livePlan = nil
            if let tn = p.dict("turn"), let id = tn.str("id") {
                let secs = tn.dbl("durationMs").map { $0 / 1000 }
                    ?? turnStarted.map { Date().timeIntervalSince($0) } ?? 0
                if let i = items.lastIndex(where: { $0.id == "tb-\(id)" }),
                   case .turnBreak(let bid, let at, _) = items[i] {
                    items[i] = .turnBreak(id: bid, at: at, duration: secs)
                }
            }
            // 回合跑失败了要说一声。
            //
            // 服务端在 `turn.error.message` 里给原因（模型不可用、超时…），
            // 以前这里整个丢掉 —— 用户看到的就是"问了没反应"。
            if let err = p.dict("turn")?.dict("error")?.str("message"), !err.isEmpty {
                banner = err
            }
            turnStarted = nil
            autoName(cur)
            saveCache()
            list.markSeen(cur)

        case "item/completed":
            flush()
            if let it = p.dict("item"), let id = it.str("id"),
               let fresh = Protocol_.item(from: it) {
                if let i = items.firstIndex(where: { $0.id == id }) {
                    items[i] = fresh
                } else if !adoptServerUser(it, fresh) {
                    items.append(fresh)
                }
                if let question = Protocol_.supplementaryQuestion(of: it) {
                    if let i = items.firstIndex(where: { $0.id == question.id }) { items[i] = question }
                    else { items.append(question) }
                }
                for (index, source) in Protocol_.toolImageSources(of: it).enumerated() {
                    let image = Item.image(id: "\(id)-image-\(index)", url: source)
                    if let i = items.firstIndex(where: { $0.id == image.id }) { items[i] = image }
                    else { items.append(image) }
                }
                tick += 1
            }

        case "thread/tokenUsage/updated":
            if let u = TokenUsage(json: p) {
                usage = u
                // 服务端只在跑回合时推一次，打开旧会话问不到 —— 记下来。
                if let id = p.str("threadId") ?? list.currentID {
                    UsageCache.save(id, u)
                }
            }

        // 计划。整份替换（服务端每次推的是完整列表）。
        case "turn/plan/updated", "thread/plan/updated":
            let steps = Protocol_.planSteps(of: p.dict("plan") ?? p)
            if !steps.isEmpty || p.arr("plan") != nil {
                upsertPlan(cur, steps: steps, turnID: p.str("turnId"))
            }

        // 计划增量：按 id 累加文本，攒到换行或结束再渲染。
        case "item/plan/delta":
            guard let id = p.str("itemId"), let d = p.str("delta") else { return }
            livePlan = id
            if !items.contains(where: { $0.id == id }) {
                items.append(.plan(id: id, steps: []))
            }
            buf["p:" + id, default: ""] += d
            scheduleFlush()

        // 本轮改了哪些文件。以前完全不处理 —— 用户要等整轮结束、
        // 再靠 turn 里的 fileChange 条目才知道改了什么。
        case "turn/diff/updated":
            if let diff = p.str("diff") {
                upsertFileChange(cur, changes: Protocol_.fileChangesFromUnifiedDiff(diff),
                                 turnID: p.str("turnId"), replacing: true)
            } else if let changes = p.arr("changes") as? [JSONDict], !changes.isEmpty {
                let fs = Protocol_.fileChangesFrom(changes)
                if !fs.isEmpty { upsertFileChange(cur, changes: fs, turnID: p.str("turnId")) }
            }

        // 队列变了（服务端共享队列，电脑端也可能往里加/删）。
        case "thread/queue/changed":
            loadQueued(cur)

        // 会话被电脑端关掉/回退：本地状态跟着收。
        case "thread/closed":
            if !localTurn { busy = false }
        case "thread/reverted":
            reload(limit: Self.firstPage)

        case "warning", "configWarning", "deprecationNotice", "guardianWarning":
            // **不进横幅。**
            //
            // 实测：服务端**每次** `thread/start` / `thread/resume` / `turn/start`
            // 都会推一条 `configWarning`，内容是
            //   "Codex is ignoring 2 unrecognized configuration settings. …"
            // 一整段英文。以前它被当成用户提示弹在屏幕底部 ——
            // 用户报的「每次点发送之后还有一筐英文弹出来」就是它。
            // 那是**服务端自己的配置告警**，跟这一轮对话无关，
            // 也轮不到聊天界面来播报。记进帧日志就够了。
            FrameLog.mark("GATE", "忽略 \(method)：\(p.str("message")?.prefix(60) ?? "")")

        case "account/rateLimits/updated":
            // 手机端走 API-key 认证，服务端给的是 primary=null 的空壳
            // （实测），界面上没有任何东西可显示，直接忽略。
            break

        case "thread/status/changed":
            guard let tid = p.str("threadId"),
                  let type = p.dict("status")?.str("type") else { return }
            let running = ThreadStatus.isRunning(type)
            // 诊断：这个会话的 status 事件到了几条、几条是"在跑"。
            // 后台通知没发时用它分辨"事件根本没到"还是"到了没通知"。
            remoteStatusEvents += 1
            if running { remoteStatusActive += 1 }
            list.setRunning(tid, running)
            if tid == cur {
                if running, !localTurn { startRemoteWatch(tid) }
                else if !running, !localTurn {
                    // 不能停轮询：对"电脑端在跑"的会话，status 报的是
                    // notLoaded（实测），停掉就再也补不上内容。刷新一次即可。
                    reload()
                    busy = false
                }
            }

        case "thread/name/updated":
            if let n = p.str("name"), let tid = p.str("threadId") {
                list.setName(tid, n)
            }

        default: break
        }
    }

    /// delta 攒 55ms 合并一次：每秒最多重绘约 18 次。
    func scheduleFlush() {
        guard flushTimer == nil else { return }
        let session = openSeq
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.055, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard self?.openSeq == session else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard !buf.isEmpty else { return }
        for (key, delta) in buf {
            if key.hasPrefix("r:") {
                appendReasoning(String(key.dropFirst(2)), delta)
            } else if key.hasPrefix("c:") {
                appendOutput(String(key.dropFirst(2)), delta)
            } else if key.hasPrefix("p:") {
                appendPlan(String(key.dropFirst(2)), delta)
            } else {
                appendAgent(key, delta)
            }
        }
        buf.removeAll()
        tick += 1
    }

    private func appendAgent(_ id: String, _ d: String) {
        if let i = items.firstIndex(where: { $0.id == id }),
           case .agent(let iid, let t) = items[i] {
            items[i] = .agent(id: iid, text: t + d)
        } else {
            items.append(.agent(id: id, text: d))
        }
    }

    private func appendReasoning(_ id: String, _ d: String) {
        if let i = items.firstIndex(where: { $0.id == id }),
           case .reasoning(let iid, let t) = items[i] {
            items[i] = .reasoning(id: iid, text: t + d)
        } else {
            items.append(.reasoning(id: id, text: d))
        }
    }

    /// 计划增量。服务端按行推，攒成整段文本再渲染。
    private func appendPlan(_ id: String, _ d: String) {
        if let i = items.firstIndex(where: { $0.id == id }),
           case .plan(let iid, let steps) = items[i] {
            items[i] = .plan(id: iid, steps: steps + [PlanStep(text: d, status: "")])
        } else {
            items.append(.plan(id: id, steps: [PlanStep(text: d, status: "")]))
        }
    }

    /// 整份计划替换（`thread/plan/updated`）。
    ///
    /// 优先就地更新已有的计划条目，没有才追加 —— 每个回合都追加一条
    /// 的话，一次长任务下来界面上会堆满十几份计划。
    func upsertPlan(_ threadId: String, steps: [PlanStep], turnID: String? = nil) {
        guard list.currentID == threadId else { return }
        let id = "plan-" + (turnID ?? serverTurnId ?? lastTurnId ?? "unscoped-" + String(openSeq))
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i] = .plan(id: items[i].id, steps: steps)
        } else {
            items.append(.plan(id: id, steps: steps))
        }
        tick += 1
    }

    /// 本轮改动：把 `turn/diff/updated` 的变更并进当前回合。
    func upsertFileChange(_ threadId: String, changes: [FileChange], turnID: String? = nil,
                          replacing: Bool = false) {
        guard list.currentID == threadId else { return }
        let stableID = "fc-" + (turnID ?? serverTurnId ?? lastTurnId ?? "unscoped-" + String(openSeq))
        // 同一批文件合并：按路径去重，后到的覆盖先到的。
        var merged = changes
        if let i = items.firstIndex(where: { $0.id == stableID }),
           case .fileChange(let id, let old) = items[i] {
            var byPath = [String: FileChange]()
            if !replacing { for c in old { byPath[c.path] = c } }
            for c in changes { byPath[c.path] = c }
            merged = Array(byPath.values).sorted { $0.path < $1.path }
            items[i] = .fileChange(id: id, changes: merged)
        } else {
            if !merged.isEmpty { items.append(.fileChange(id: stableID, changes: merged)) }
        }
        tick += 1
    }

    private func appendOutput(_ id: String, _ d: String) {
        if let i = items.firstIndex(where: { $0.id == id }),
           case .command(let iid, let cmd, let out) = items[i] {
            items[i] = .command(id: iid, command: cmd, output: out + d)
        }
    }


    /// 首轮跑完给会话起个名字。
    ///
    /// 服务端不会自动命名，列表里一水儿的"新会话"，找不着。
    /// 用第一条用户消息当标题，太长就截断。
    private func autoName(_ tid: String) {
        guard let t = list.thread(tid), !t.named else { return }
        guard let first = items.first(where: {
            if case .user = $0 { return true }
            return false
        }) else { return }
        var s = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.split(separator: "\n").first.map(String.init) ?? s
        guard !s.isEmpty else { return }
        if s.count > 18 { s = String(s.prefix(18)) + "…" }
        list.rename(t, to: s)
    }
}

import Foundation

/// 把一串条目按"回合"分组的显示层。
///
/// 用户截图里的问题：一次任务下来，`已思考`、`/bin/bash -lc ...` 各占一行，
/// 十几行中间过程把真正的回复挤到屏幕外。
///
/// 规则（照 Happy 的 `useGroupedMessages`）：
///   - 回合**进行中**：全部平铺（正在发生的事要看得见）
///   - 回合**结束**：中间过程折叠成一组，只留最终回复在外面
///   - 展开后**跟流式时长得一模一样**，不是另一种样式
enum Grouping {

    /// 一条回合里"中间过程"的条目 —— 思考、命令、工具、改文件、计划。
    static func isWork(_ it: Item) -> Bool {
        switch it {
        case .reasoning, .command, .tool, .fileChange, .plan, .note, .compaction:
            return true
        // `.question` 不折叠：agent 在等人回答，藏起来用户就卡住了。
        case .user, .agent, .image, .turnBreak, .question:
            return false
        }
    }

    /// 折叠后的一行。
    enum Row: Identifiable {
        /// 普通条目，照原样渲染。
        case one(Item)
        /// 一个回合的中间过程，收起时只显示摘要。
        case work(id: String, items: [Item], live: Bool, duration: Double?)

        var id: String {
            switch self {
            case .one(let i): return i.id
            case .work(let id, _, _, _): return id
            }
        }
    }

    /// 分组。
    ///
    /// `liveTurnId` 是**正在进行**的那个回合 id（`nil` = 没有在跑）。
    /// 进行中的回合不折叠：里面的内容每一秒都在变，折叠起来反而看不到进展。
    /// 一个回合内的条目顺序纠正。
    ///
    /// 服务端的流是**按到达顺序**给的，而思考摘要经常比正文晚到
    /// （`item/reasoning/summaryPartAdded` / `item/reasoning/textDelta`
    /// 会跟在 agentMessage 的 delta 后面）。直接按到达顺序渲染，
    /// 看到的就是"结论后面还挂着一整段思考" —— 用户报的就是这个。
    ///
    /// 这里按回合（两条 turnBreak 之间）做一次**稳定**重排：
    /// 用户消息 → 思考 → 其余（命令/工具/正文）。
    /// 稳定 = 同类之间相对顺序不变，所以正文里穿插的命令不会被挪乱。
    static func ordered(_ items: [Item]) -> [Item] {
        var out: [Item] = []
        var seg: [Item] = []

        func flushSeg() {
            defer { seg.removeAll() }
            guard seg.count > 1 else { out.append(contentsOf: seg); return }
            // 稳定分桶：0 用户 / 1 分隔线 / 2 思考 / 3 其余。
            //
            // 分隔线必须排在**思考前面**，不能跟着"其余"一起走。
            // `rows()` 靠"用户消息之后那条分隔线"认回合边界（pendingBreak
            // 一设，后面攒的过程条目才有归属）；分隔线排在思考后面的话，
            // 思考落在 pendingBreak 还没设的时候，永远折不起来，
            // 只能当一条裸行挂在回复下面。
            var buckets: [[Item]] = [[], [], [], []]
            for it in seg {
                switch it {
                case .user: buckets[0].append(it)
                case .turnBreak: buckets[1].append(it)
                case .reasoning: buckets[2].append(it)
                default: buckets[3].append(it)
                }
            }
            out.append(contentsOf: buckets.flatMap { $0 })
        }

        for it in items {
            // **回合边界是用户消息，不是分隔线。**
            //
            // 以前只在分隔线处切段。实测（探针 dump）一个段里会横跨两个
            // 回合：上一轮晚到的思考 + 下一轮的用户消息。排序时下一轮的
            // 用户消息被顶到段首，上一轮的思考就被挤到回复后面 ——
            // 用户报的「回复下面还有思考」。
            if case .user = it {
                flushSeg()
                seg.append(it)
                continue
            }
            seg.append(it)
        }
        flushSeg()
        return out
    }

    /// 把分隔线归位到它**所属回合的开头**，并去掉重复的。
    ///
    /// 数据层里分隔线的位置是坏的，两个来源各错一半：
    ///
    ///   1. `Protocol_.items(fromTurn:)` 把它**追加在回合末尾**。回合还在跑时
    ///      服务端只返回 `[用户消息]`，那条分隔线就落在用户消息正后面 ——
    ///      等于插在回合中间。之后到的思考、正文全被算进了下一段，
    ///      渲染出来就是「回复下面还有思考」。
    ///   2. `send()` 每发一条消息都插一条 `tb-local-` 分隔线，而且永远没人
    ///      清理它（`turn/completed` 只认服务端那条 id），于是每发一条消息
    ///      就永久多一条 `duration=nil` 的假分隔线。
    ///
    /// 规则：一条分隔线属于**离它最近、且在它前面**的那条用户消息所在回合。
    /// 把它挪到那条用户消息**之后**（`rows()` 的约定）。前面没有用户消息的
    /// （本来就放对了）原地不动。
    /// 归位后挨在一起的，只留一条 —— 优先留有耗时的（服务端那条）。
    ///
    /// 实测数据（探针 dump，两个回合）：
    ///   坏：U T(7s) A R T(nil) U T(4s) R A
    ///   好：T(7s) U R A T(4s) U R A
    static func normalizeBreaks(_ items: [Item]) -> [Item] {
        var slots: [Int: [Item]] = [:]     // 目标下标 → 要插到它前面的分隔线
        var drop = Set<Int>()
        var target: Int?
        for (i, it) in items.enumerated() {
            if case .user = it { target = i }
            guard it.isTurnBreak else { continue }
            guard let t = target else { continue }   // 前面没有用户消息：放对了
            slots[t, default: []].append(it)
            drop.insert(i)
        }
        if slots.isEmpty { return items }

        var out: [Item] = []
        for (i, it) in items.enumerated() {
            if !drop.contains(i) { out.append(it) }
            // 插在用户消息**之后** —— `rows()` 就是靠"用户消息之后紧跟的
            // 那条分隔线"来认回合边界的（见 rows 里 pendingBreak 的用法）。
            if let head = slots[i] { out.append(pickOne(head)) }
        }
        // 归位后可能跟原来的分隔线挨在一起，再扫一遍去重。
        var dedup: [Item] = []
        for it in out {
            if it.isTurnBreak, let last = dedup.last, last.isTurnBreak {
                dedup[dedup.count - 1] = pickOne([last, it])
                continue
            }
            dedup.append(it)
        }
        return dedup
    }

    /// 一组重叠的分隔线里留哪条：有耗时的优先（服务端那条）。
    private static func pickOne(_ group: [Item]) -> Item {
        for it in group {
            if case .turnBreak(_, _, let d) = it, d != nil { return it }
        }
        return group[0]
    }

    /// `gen` 是**调用方**的内容代数（`ConversationModel.gen`）：`items` 每变一次 +1。
    ///
    /// 必须由调用方传进来，不能在这里存全局变量。踩过的坑：早先缓存的键是
    /// 模块级的 `Grouping.gen`，谁都能推进它 —— 单元测试之间会互相串，
    /// 10 条老测试直接变红（新内容和旧缓存撞在同一个代数上）。
    /// 调用方不给（`nil`）就老老实实重算，不缓存。
    static func rows(_ items: [Item], liveTurnId: String?, gen: Int? = nil) -> [Row] {
        guard let gen else { return rowsUncached(items, liveTurnId: liveTurnId) }
        if let c = rowsCache, c.gen == gen, c.live == liveTurnId { return c.value }
        let v = rowsUncached(items, liveTurnId: liveTurnId)
        rowsCache = (gen, liveTurnId, v)
        return v
    }

    private static func rowsUncached(_ items: [Item], liveTurnId: String?) -> [Row] {
        // 历史缓存可能早于 Protocol_ 的空白 agent 过滤生成；这里再挡一层，
        // 否则旧缓存仍会留下只有标题/空白间距的行。含真实字符的正文原样保留。
        let visible = items.filter { item in
            guard case .agent(_, let text) = item else { return true }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // 顺序要紧：**先归一分隔线，再按回合排序**。
        // 反过来做的话，被劈成两半的回合会先被独立排序，思考就跑到
        // 上一轮回复后面去了（用户报的「回复下面还有思考」）。
        let items = ordered(normalizeBreaks(visible))
        return rowsOfSorted(items, liveTurnId: liveTurnId)
    }

    /// 整份 `rows()` 结果的一格缓存。见 `rows(_:liveTurnId:gen:)`。
    ///
    /// 只缓存 `ordered` 不够：`normalizeBreaks` 实测还有 1.79ms，
    /// 而 `rows()` 一次 body 要被调两遍（列表一遍 + 常驻探针 `orderProbe`
    /// 一遍）。滑动时 body 每秒重算十几次，这笔账乘出来就是"上下滑好卡"。
    private static var rowsCache: (gen: Int, live: String?, value: [Row])?

    private static func rowsOfSorted(_ items: [Item], liveTurnId: String?) -> [Row] {
        var out: [Row] = []
        var pending: [Item] = []          // 攒着的工作条目
        var pendingBreak: Item? = nil     // 这一组属于哪条分隔线

        func flushWork() {
            defer { pending.removeAll(); pendingBreak = nil }
            guard !pending.isEmpty else { return }
            // 没有分隔线兜着 = 没有回合边界，**不折叠**，原样平铺。
            // 折的话会凭空造一个回合出来，用户看到的组是对不上的。
            guard let brk = pendingBreak else {
                for it in pending { out.append(.one(it)) }
                return
            }
            if case .turnBreak(_, _, let dur) = brk {
                let isLive = liveTurnId != nil && brk.id == "tb-\(liveTurnId!)"
                if pending.isEmpty {
                    // 这个回合没有任何过程条目（用户问、助手直接答）。
                    // 折叠组里只有分隔线的话，摘要会算成"1 步"，界面上凭空
                    // 多出一条"1 步 12 秒"。这种情况直接出分隔线本身。
                    out.append(.one(brk))
                } else if isLive {
                    // 进行中：不折叠，全平铺。
                    out.append(.one(brk))
                    for it in pending { out.append(.one(it)) }
                } else {
                    // 已结束：把分隔线本身也收进组里，只留一条摘要行。
                    var members = [brk]
                    members.append(contentsOf: pending)
                    out.append(.work(id: "work-" + brk.id, items: members,
                                     live: false, duration: dur))
                }
            } else {
                out.append(.one(brk))
                for it in pending { out.append(.one(it)) }
            }
        }

        for it in items {
            if it.isTurnBreak {
                // 遇到新分隔线：上一组收口。
                flushWork()
                pendingBreak = it
                continue
            }
            if isWork(it) {
                // 还没有分隔线就先攒着（回合刚开始、turn/started 还没到）；
                // 一直没等到就按"没有回合边界"处理，平铺出去。
                pending.append(it)
                continue
            }
            // 用户消息 / 助手回复 / 图片：结束当前组，自己单独一行。
            flushWork()
            out.append(.one(it))
        }
        flushWork()
        return out
    }
}

extension Grouping.Row {
    /// 收起时那行摘要写什么。
    var summary: String {
        switch self {
        case .one(let i):
            if case .turnBreak(_, _, let d) = i, let d { return TurnDivider.short(d) }
            return ""
        case .work(_, let items, _, _):
            let cmd = items.filter { if case .command = $0 { return true }; return false }.count
            let tool = items.filter { if case .tool = $0 { return true }; return false }.count
            let file = items.filter { if case .fileChange = $0 { return true }; return false }.count
            let plan = items.filter { if case .plan = $0 { return true }; return false }.count
            let reason = items.filter { if case .reasoning = $0 { return true }; return false }.count
            var parts: [String] = []
            if plan > 0 { parts.append("计划") }
            if reason > 0 { parts.append("思考 \(reason) 次") }
            if cmd > 0 { parts.append("命令 \(cmd) 条") }
            if tool > 0 { parts.append("工具 \(tool) 次") }
            if file > 0 { parts.append("改文件 \(file) 处") }
            return parts.isEmpty ? "\(items.count) 步" : parts.joined(separator: " · ")
        }
    }
}

extension Grouping {
    /// 条目类型的一个字母，只给探针和测试读。
    /// U 用户 / R 思考 / A 正文 / C 命令 / X 工具 / F 改动 / P 计划 / T 分隔线。
    static func letter(_ it: Item) -> String {
        switch it {
        case .user: return "U"
        case .agent: return "A"
        case .reasoning: return "R"
        case .command: return "C"
        case .tool: return "X"
        case .fileChange: return "F"
        case .plan: return "P"
        case .turnBreak: return "T"
        default: return "o"
        }
    }
}

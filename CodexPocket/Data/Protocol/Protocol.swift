import Foundation

/// app-server 协议 → 界面模型。
///
/// 视图层不碰协议：所有 `item/*`、`turn/*`、`thread/*` 事件都在这里翻译成
/// `Item`。协议变了只改这一个文件。
enum Protocol_ {

    // MARK: - 会话

    /// `thread/search` 的回包：`{"data":[{"thread":{...},"snippet":"..."}]}`。
    ///
    /// 结构和 `thread/list` **不一样** —— thread 是嵌在 `thread` 字段里的，
    /// 外面还多一个 `snippet`（命中的那段原文）。直接套 `threads(from:)`
    /// 会一条都解析不出来。
    static func searchHits(from result: Any) -> (hits: [Thread], snippets: [String: String]) {
        let rows = (result as? JSONDict)?.dicts("data") ?? []
        var hits: [Thread] = []
        var snips: [String: String] = [:]
        for r in rows {
            guard let t = r.dict("thread"), let one = Thread(json: t) else { continue }
            hits.append(one)
            if let sn = r.str("snippet"), !sn.isEmpty { snips[one.id] = sn }
        }
        return (dedupe(hits), snips)
    }

    static func threads(from result: Any) -> [Thread] {
        let rows = (result as? JSONDict)?.dicts("data") ?? []
        return dedupe(rows.compactMap { Thread(json: $0) })
    }

    /// 同一个 **id** 出现多行时只留最新的一条。
    ///
    /// **不能按「标题 + 目录」去重。**
    ///
    /// 以前是那样做的，理由是"fork 副本会同时出现在列表里"。实测真实
    /// `thread/list` 的 33 行里，`forkedFromId` **全是 null**；而
    /// `"新会话|/Users/test"` 这一组里有 **10 个不同的 id** ——
    /// 全是用户自己新建的会话，标题都叫"新会话"。按标题去重等于
    /// **把 9 个会话从列表里抹掉**（用户报的"会话名字相同会覆盖"）。
    ///
    /// 真正的重复是**同一个 id 出现多行**（实测 `01a0bb40-4` 出现 7 次，
    /// updatedAt 各不相同）—— 那种按 id 留最新就对了。
    static func dedupe(_ rows: [Thread]) -> [Thread] {
        var seen = Set<String>()
        var out: [Thread] = []
        for t in rows.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard !seen.contains(t.id) else { continue }
            seen.insert(t.id)
            out.append(t)
        }
        return out
    }

    // MARK: - 一个回合的 turns/list 回包 → items

    static func items(fromTurns result: Any) -> [Item] {
        var turns = (result as? JSONDict)?.dicts("data")
            ?? (result as? JSONDict)?.dicts("turns") ?? []
        // `thread/turns/list` 默认 **desc**（最新在前）。调用方应该显式传
        // sortDirection: "asc"，漏传时这里兜一下 —— 否则最新的一条会跑到
        // 列表最上面（用户："我发的新消息怎么变成最上面的一条了"）。
        if turns.count > 1,
           let a = turnTime(turns[0]), let b = turnTime(turns[turns.count - 1]),
           a > b {
            turns.reverse()
        }
        var out: [Item] = []
        for tp in turns { out.append(contentsOf: items(fromTurn: tp)) }
        return out
    }

    /// 回合时间戳（秒或毫秒都见过），排序用。
    private static func turnTime(_ t: JSONDict) -> Double? {
        guard let v = t.dbl("startedAt") ?? t.dbl("createdAt") else { return nil }
        return v > 1e11 ? v : v * 1000
    }

    /// 一个回合 → 条目。
    ///
    /// 真实结构（实测 thread/turns/list 的回包）：
    ///   turn = { id, items, itemsView, status, error, startedAt, completedAt, durationMs }
    ///   item = { type, id, ... }
    ///     userMessage  { clientId, content: [{ type:"text", text }] }
    ///     agentMessage { text, phase, memoryCitation, delivery, questions }
    ///     reasoning    { summary: [], content: [] }
    ///
    /// 注意：用户消息在 **items** 里，不是 turn.input —— 之前按 input 解析，
    /// 用户消息会全部丢掉（实测确认）。
    static func items(fromTurn tp: JSONDict) -> [Item] {
        var out: [Item] = []
        let started = date(tp.dbl("startedAt")) ?? Date()
        var duration = tp.dbl("durationMs").map { $0 / 1000 }
        if duration == nil, let done = date(tp.dbl("completedAt")) {
            duration = done.timeIntervalSince(started)
        }
        for it in tp.dicts("items") {
            if let one = item(from: it) { out.append(one) }
            if let question = supplementaryQuestion(of: it) { out.append(question) }
            for (index, source) in toolImageSources(of: it).enumerated() {
                out.append(.image(id: "\(it.str("id") ?? "tool")-image-\(index)", url: source))
            }
        }
        // 用时挂在分隔线上，不单独浮一条。
        out.append(.turnBreak(id: "tb-" + (tp.str("id") ?? UUID().uuidString),
                              at: started, duration: duration))
        return out
    }

    // MARK: - 单条 item

    static func item(from it: JSONDict) -> Item? {
        let id = it.str("id") ?? UUID().uuidString
        let type = it.str("type") ?? it.str("itemType") ?? ""

        switch type {
        // 用户消息：content 是数组，取里面的 text。
        case "userMessage", "user":
            let t = content(of: it)
            let imgs = imagePaths(of: it)
            let client = it.str("clientId") ?? it.str("clientUserMessageId") ?? ""
            let identity = client.isEmpty ? id : client
            return (t.isEmpty && imgs.isEmpty) ? nil : .user(id: identity, text: t, images: imgs)

        case "agentMessage", "assistantMessage", "message":
            // agent 反过来问用户：先当问题渲染，没有正文也没关系。
            let qs = questions(of: it)
            if !qs.isEmpty, (it.str("text") ?? "").isEmpty {
                return .question(id: id, prompts: qs)
            }
            let t = it.str("text") ?? content(of: it)
            // 历史回包里会有只含空格/换行的 msg_ft 或占位 agent item。
            // 保留它会让 MessageRow 画出「Codex」标题，但 Markdown 没有任何
            // block，用户看到一屏空标题。流式事件的空占位不经过这里，仍由
            // ConversationEvents 保留，等待 delta 填正文。
            return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : .agent(id: id, text: t)

        case "imageView":
            guard let path = it.str("path"), !path.isEmpty else {
                return .note(id: id, label: "查看图片", detail: "图片路径未返回")
            }
            return .image(id: id, url: path)

        case "imageGeneration", "imageGen":
            if let path = it.str("savedPath"), !path.isEmpty { return .image(id: id, url: path) }
            if let value = it.str("result"), !value.isEmpty {
                if value.hasPrefix("data:image/") { return .image(id: id, url: value) }
                let formats = [("iVBORw0KGgo", "png"), ("/9j/", "jpeg"),
                               ("R0lGOD", "gif"), ("UklGR", "webp")]
                if let format = formats.first(where: { value.hasPrefix($0.0) }) {
                    return .image(id: id, url: "data:image/\(format.1);base64," + value)
                }
                return .note(id: id, label: "生成图片", detail: value)
            }
            return .note(id: id, label: "生成图片", detail: it.str("status") ?? "尚无结果")

        case "reasoning", "reasoningSummary":
            // 真实结构：思考过程在 `summary` 数组里，`content` 通常是空的。
            // 只读 content 的话思考过程全丢（用户："为什么不显示思考过程"）。
            let t = reasoningText(of: it)
            return t.isEmpty ? nil : .reasoning(id: id, text: t)

        case "commandExecution", "execCommand", "command":
            let cmd = it.str("command") ?? (it.arr("command") as? [String])?.joined(separator: " ") ?? ""
            let out = it.str("aggregatedOutput") ?? it.str("output") ?? ""
            return cmd.isEmpty && out.isEmpty ? nil : .command(id: id, command: cmd, output: out)

        case "fileChange", "applyPatch", "patch":
            let changes = fileChanges(it)
            return changes.isEmpty ? nil : .fileChange(id: id, changes: changes)

        case "mcpToolCall", "toolCall", "functionCall", "dynamicToolCall":
            return .tool(id: id,
                         server: it.str("server") ?? it.str("serverName") ?? "",
                         tool: it.str("tool") ?? it.str("name") ?? "",
                         status: it.str("status") ?? "",
                         args: jsonText(it["arguments"] ?? it["args"]),
                         result: jsonText(withoutImagePayload(it["result"] ?? it["output"] ?? it["contentItems"])),
                         ms: it.dbl("durationMs") ?? 0)

        case "contextCompaction", "compaction":
            return .compaction(id: id)

        // 计划 / 待办。以前这两种都没有分支，直接掉进 default，
        // 而它们通常没有 `text` 字段 → 被丢掉 → 用户看不到 agent 的计划。
        case "plan", "todo", "todoList":
            let steps = planSteps(of: it)
            return steps.isEmpty ? nil : .plan(id: id, steps: steps)

        // 纯噪音，不渲染：这两个是节流/工具内部事件，没有用户可读内容。
        case "sleep", "clockSleep", "commandExecutionOutputDelta":
            return nil

        default:
            // 兜底：有文本的当助手回复，别把内容整份丢掉。
            let t = text(of: it)
            if !t.isEmpty { return .agent(id: id, text: t) }
            // 连文本都没有的（imageView / webSearch / 多 agent 协作 /
            // 以后新增的类型…）**不能静默丢**。渲染成一条中性的折叠行，
            // 至少让用户知道"这里发生过一件事"。
            return .note(id: id, label: noteLabel(type), detail: noteDetail(it))
        }
    }

    /// `agentMessage.questions` → 问题列表。
    static func supplementaryQuestion(of item: JSONDict) -> Item? {
        guard let content = self.item(from: item), case .agent = content else { return nil }
        let questions = questions(of: item)
        guard !questions.isEmpty else { return nil }
        return .question(id: content.id + "-questions", prompts: questions)
    }

    ///
    /// 真实结构（按实测与 schema 推）：
    ///   questions: [{ id, header, question, options: [{ label, description }] }]
    /// 字段名在不同版本里叫法不一，挨个试，认不出就不渲染（宁可不显示，
    /// 也不要凭空造出一个"问题"让用户对着空气点）。
    static func questions(of it: JSONDict) -> [Question] {
        guard let raw = it.arr("questions"), !raw.isEmpty else { return [] }
        var out: [Question] = []
        for (i, q) in raw.enumerated() {
            guard let d = q as? JSONDict else { continue }
            let text = d.str("question") ?? d.str("text") ?? d.str("prompt") ?? ""
            let header = d.str("header") ?? d.str("title") ?? ""
            let opts = (d.arr("options") ?? []).compactMap { o -> Question.Option? in
                if let s = o as? String { return Question.Option(id: s, label: s, detail: "") }
                guard let od = o as? JSONDict else { return nil }
                let label = od.str("label") ?? od.str("title") ?? od.str("value") ?? ""
                guard !label.isEmpty else { return nil }
                return Question.Option(id: label, label: label,
                                       detail: od.str("description") ?? od.str("detail") ?? "")
            }
            guard !text.isEmpty || !opts.isEmpty else { continue }
            out.append(Question(id: d.str("id") ?? "q\(i)", header: header,
                                text: text, options: opts))
        }
        return out
    }

    /// 计划条目：`steps` / `items` / `todos` 都见过，字段名按这个顺序试。
    static func planSteps(of it: JSONDict) -> [PlanStep] {
        for key in ["steps", "items", "todos", "plan"] {
            guard let raw = it.arr(key), !raw.isEmpty else { continue }
            let out: [PlanStep] = raw.compactMap { p in
                guard let d = p as? JSONDict else {
                    if let s = p as? String { return PlanStep(text: s, status: "") }
                    return nil
                }
                let t = d.str("text") ?? d.str("step") ?? d.str("content")
                    ?? d.str("title") ?? d.str("description") ?? ""
                guard !t.isEmpty else { return nil }
                return PlanStep(text: t, status: d.str("status") ?? "")
            }
            if !out.isEmpty { return out }
        }
        // 只有一个整体文本的计划（`item/plan/delta` 那种）。
        if let t = it.str("text"), !t.isEmpty { return [PlanStep(text: t, status: "")] }
        return []
    }

    /// 认不出的条目在界面上叫什么。
    static func noteLabel(_ type: String) -> String {
        switch type {
        case "imageView": return "查看图片"
        case "webSearch", "web_search": return "联网搜索"
        case "imageGeneration", "imageGen": return "生成图片"
        case "collabAgentToolCall", "collabAgent": return "多 Agent 协作"
        case "enteredReviewMode", "review": return "进入评审模式"
        case "hookPrompt", "hook": return "钩子"
        case "mcpToolCallProgress": return "工具进度"
        case "": return "事件"
        default: return type
        }
    }

    /// 中性条目的副标题：尽量给一条能看出所以然的摘要。
    static func noteDetail(_ it: JSONDict) -> String {
        for key in ["query", "path", "name", "url", "command", "tool", "status"] {
            if let v = it.str(key), !v.isEmpty { return v }
        }
        if let t = it.str("text"), !t.isEmpty { return t }
        // 都没有就把条目里的标量字段列成 `key=value` ——
        // 只列键名（"foo"）看不出任何东西，带上值才能判断这是什么事件。
        var parts: [String] = []
        for k in it.keys.sorted() where k != "type" && k != "id" {
            guard let v = it[k] as? String ?? (it[k] as? NSNumber)?.stringValue else { continue }
            if v.isEmpty { continue }
            parts.append("\(k)=\(v)")
            if parts.count >= 4 { break }
        }
        return parts.joined(separator: ", ")
    }

    /// 思考过程：`summary` 是数组（字符串或 {text}），`content` 兜底。
    static func reasoningText(of it: JSONDict) -> String {
        var parts: [String] = []
        for key in ["summary", "content"] {
            for p in it.arr(key) ?? [] {
                if let s = p as? String { parts.append(s) }
                else if let d = p as? JSONDict,
                        let s = d.str("text") ?? d.str("content") { parts.append(s) }
            }
        }
        if parts.isEmpty, let s = it.str("text") { parts.append(s) }
        return parts.joined(separator: "\n\n")
    }

    static func text(of it: JSONDict) -> String {
        it.str("text") ?? content(of: it)
    }

    /// 把 content 数组里的文本拼起来。
    static func content(of it: JSONDict) -> String {
        let parts = it.arr("content") ?? it.arr("contentItems") ?? []
        return parts.compactMap { p -> String? in
            guard let d = p as? JSONDict else { return p as? String }
            return d.str("text") ?? d.str("content")
        }.joined()
    }

    /// content 里的图片路径。
    static func imagePaths(of it: JSONDict) -> [String] {
        let parts = it.arr("content") ?? []
        return parts.compactMap { p -> String? in
            guard let d = p as? JSONDict else { return nil }
            let t = d.str("type") ?? ""
            guard t == "image" || t == "inputImage" || t == "localImage" else { return nil }
            // `image` 的载荷是 `url`（服务端回读历史时是 data URL，几百 KB），
            // `localImage` 才是 `path`。顺序不能反：先取 path 会把
            // data URL 当成路径。
            return d.str("path") ?? d.str("url") ?? d.str("imageUrl") ?? d.str("image_url")
        }
    }

    static func toolImageSources(of item: JSONDict) -> [String] {
        let content = item.dict("result")?.dicts("content") ?? item.dicts("contentItems")
        return content.compactMap { part in
            switch part.str("type") {
            case "image":
                if let data = part.str("data") {
                    return "data:\(part.str("mimeType") ?? "image/png");base64,\(data)"
                }
                return part.str("url")
            case "inputImage", "input_image":
                return part.str("imageUrl") ?? part.str("image_url")
            default: return nil
            }
        }
    }

    private static func withoutImagePayload(_ value: Any?) -> Any? {
        if let parts = value as? [Any] { return parts.compactMap { withoutImagePayload($0) } }
        guard var object = value as? JSONDict else { return value }
        if ["image", "inputImage", "input_image"].contains(object.str("type") ?? "") { return nil }
        if let content = object["content"] { object["content"] = withoutImagePayload(content) }
        return object
    }

    /// 一批裸的 change 对象 → FileChange。
    static func fileChangesFromUnifiedDiff(_ diff: String) -> [FileChange] {
        var result: [FileChange] = [], lines: [String] = []
        var oldPath: String?, newPath: String?
        var inHunk = false
        var added = 0, removed = 0
        func path(_ line: String) -> String {
            let raw = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
            return raw.hasPrefix("a/") || raw.hasPrefix("b/") ? String(raw.dropFirst(2)) : raw
        }
        func finish() {
            guard let file = newPath == "/dev/null" ? oldPath : newPath ?? oldPath else { return }
            let patch = lines.joined(separator: "\n")
            result.append(FileChange(path: file,
                kind: oldPath == "/dev/null" ? "add" : (newPath == "/dev/null" ? "delete" : "update"),
                diff: patch, added: added, removed: removed))
        }
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                finish(); lines = []; oldPath = nil; newPath = nil; inHunk = false
                added = 0; removed = 0
                if let separator = line.range(of: " b/", options: .backwards) {
                    newPath = String(line[separator.upperBound...])
                }
            }
            if line.hasPrefix("@@") { inHunk = true }
            if !inHunk, line.hasPrefix("--- ") { oldPath = path(line) }
            if !inHunk, line.hasPrefix("+++ ") { newPath = path(line) }
            if inHunk, line.hasPrefix("+") { added += 1 }
            if inHunk, line.hasPrefix("-") { removed += 1 }
            lines.append(line)
        }
        finish()
        return result
    }

    static func fileChangesFrom(_ raw: [JSONDict]) -> [FileChange] {
        raw.compactMap { c in
            guard let p = c.str("path") ?? c.str("file") else { return nil }
            let diff = c.str("diff") ?? c.str("patch") ?? ""
            let kind = c.str("kind") ?? c.str("type") ?? "update"
            return FileChange(path: p, kind: kind, diff: diff,
                              added: c.int("added") ?? count(diff, "+"),
                              removed: c.int("removed") ?? count(diff, "-"))
        }
    }

    static func fileChanges(_ it: JSONDict) -> [FileChange] {
        let raw = it.arr("changes") as? [JSONDict] ?? it.arr("files") as? [JSONDict] ?? []
        return raw.compactMap { c in
            guard let p = c.str("path") ?? c.str("file") else { return nil }
            let diff = c.str("diff") ?? c.str("patch") ?? ""
            let kind = c.str("kind") ?? c.str("type") ?? "update"
            return FileChange(path: p, kind: kind, diff: diff,
                              added: c.int("added") ?? count(diff, "+"),
                              removed: c.int("removed") ?? count(diff, "-"))
        }
    }

    /// 新增文件的 diff 就是正文（没有 + 前缀），别按统一 diff 数。
    static func count(_ diff: String, _ sign: Character) -> Int {
        diff.split(separator: "\n").filter {
            $0.hasPrefix(String(sign)) && !$0.hasPrefix("\(sign)\(sign)\(sign)")
        }.count
    }

    static func jsonText(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let d as JSONDict:
            if let t = d.str("text") { return t }
            guard let data = try? JSONSerialization.data(withJSONObject: d,
                                                        options: [.prettyPrinted, .sortedKeys])
            else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: v as Any,
                                                        options: [.prettyPrinted, .sortedKeys])
            else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    static func isImage(_ p: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((p as NSString).pathExtension.lowercased())
    }

    static func date(_ ts: Double?) -> Date? {
        guard let ts, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts > 1e11 ? ts / 1000 : ts)
    }
}

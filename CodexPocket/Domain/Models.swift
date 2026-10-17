import Foundation

// MARK: - 会话

struct Thread: Identifiable, Hashable {
    let id: String
    var title: String
    var model: String
    /// 这个会话的推理强度。服务端没给就空，用设置里的默认值。
    var effort: String
    /// 服务端有没有给过名字。没有的话 title 只是首条消息摘要。
    var named: Bool
    var cwd: String
    /// 服务端给的项目归属；null 也可能是旧目录项目，需要按工作目录回退。
    var projectId: String?
    /// 是否返回项目字段。
    var hasProjectMetadata: Bool
    /// 桌面明确标为无项目；由 bridge 只读桌面持久状态补充。
    var desktopProjectless: Bool
    var updatedAt: Date
    var running: Bool
    var unread: Bool
    var archived: Bool
    /// 列表里显示的标题：服务端没给名字就用首条消息摘要。
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "新会话" : t
    }

    init?(json: JSONDict) {
        guard let id = json.str("id") else { return nil }
        self.id = id
        self.title = json.str("name") ?? json.str("preview") ?? ""
        self.model = json.str("model") ?? ""
        self.effort = json.str("reasoningEffort") ?? ""
        self.named = json.str("name") != nil
        self.cwd = json.str("cwd") ?? ""
        self.projectId = json.str("projectId")
        self.hasProjectMetadata = json.keys.contains("projectId")
        self.desktopProjectless = json.bool("desktopProjectless") ?? false
        let ts = json.dbl("updatedAt") ?? json.dbl("createdAt") ?? 0
        self.updatedAt = Date(timeIntervalSince1970: ts > 1e11 ? ts / 1000 : ts)
        let status = json.dict("status")?.str("type") ?? json.str("status") ?? ""
        self.running = ThreadStatus.isRunning(status)
        self.unread = false
        self.archived = json.bool("archived") ?? false
    }
}

// MARK: - 项目

struct Project: Identifiable, Hashable {
    let id: String
    var name: String
    var roots: [String]

    init?(json: JSONDict) {
        guard let id = json.str("id") else { return nil }
        self.id = id
        let nm = json.str("name")
        self.name = (nm?.isEmpty == false ? nm! : id)
        // roots 是 [{"path": "..."}]，不是字符串数组 —— 早先按 strs 解析
        // 得到空数组，结果所有会话都掉进「无项目」（实测 7 条知识库会话全丢）。
        let raw = json.arr("roots") ?? []
        var paths: [String] = []
        for r in raw {
            if let d = r as? JSONDict, let p = d.str("path") { paths.append(p) }
            else if let s = r as? String { paths.append(s) }
        }
        self.roots = paths
    }

    /// 这条会话属不属于这个项目。服务端给了 projectId 就用它，
    /// 否则按工作目录前缀匹配（跟桌面端一致）。
    func owns(_ t: Thread) -> Bool {
        if !t.cwd.isEmpty {
            for r in roots where t.cwd == r || t.cwd.hasPrefix(r.hasSuffix("/") ? r : r + "/") {
                return true
            }
        }
        return false
    }
}

// MARK: - 模型与推理强度

struct EffortOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let efforts: [EffortOption]
    let defaultEffort: String

    init?(json: JSONDict) {
        guard let id = json.str("id") else { return nil }
        self.id = id
        let dn = json.str("displayName") ?? ""
        self.name = dn.isEmpty ? id : dn
        self.detail = json.str("description") ?? ""
        self.efforts = json.dicts("supportedReasoningEfforts").compactMap { e in
            guard let v = e.str("reasoningEffort") ?? e.str("id") else { return nil }
            return EffortOption(id: v, name: e.str("displayName") ?? v)
        }
        self.defaultEffort = json.str("defaultReasoningEffort") ?? efforts.first?.id ?? ""
    }
}

// MARK: - 会话内容

/// 会话里的一条。渲染层按类型分派。
enum Item: Identifiable, Hashable {
    case user(id: String, text: String, images: [String])
    case agent(id: String, text: String)
    case reasoning(id: String, text: String)
    case command(id: String, command: String, output: String)
    case fileChange(id: String, changes: [FileChange])
    case tool(id: String, server: String, tool: String, status: String, args: String, result: String, ms: Double)
    case compaction(id: String)
    case image(id: String, url: String)
    /// 计划 / 待办（`thread/plan/updated`、`item/plan/delta`）。
    case plan(id: String, steps: [PlanStep])
    /// agent 反过来问用户问题（`agentMessage.questions`）。
    /// 以前只解析不渲染 —— 用户看到 agent 停在那儿不动，其实它在等人答。
    case question(id: String, prompts: [Question])
    /// 认不出的条目。
    ///
    /// 以前 `default` 分支对"没有文本的条目"直接返回 nil —— 服务端发的
    /// plan / todo / sleep / imageView / webSearch / 多 agent 协作等
    /// 十几种条目**在界面上凭空消失**，用户看到的是一段内容莫名其妙断掉。
    /// 现在一律渲染成一条中性的折叠行，宁可多一行也不静默丢。
    case note(id: String, label: String, detail: String)
    case turnBreak(id: String, at: Date, duration: Double?)

    var id: String {
        switch self {
        case .user(let i, _, _), .agent(let i, _), .reasoning(let i, _),
             .command(let i, _, _), .fileChange(let i, _), .tool(let i, _, _, _, _, _, _),
             .compaction(let i), .image(let i, _), .plan(let i, _),
             .note(let i, _, _), .turnBreak(let i, _, _), .question(let i, _):
            return i
        }
    }

    var isAgent: Bool { if case .agent = self { return true }; return false }
    var isTurnBreak: Bool { if case .turnBreak = self { return true }; return false }
    var text: String {
        switch self {
        case .user(_, let t, _), .agent(_, let t), .reasoning(_, let t): return t
        default: return ""
        }
    }
}

/// 计划里的一步。
struct PlanStep: Hashable {
    var text: String
    /// `pending` / `inProgress` / `completed`。
    var status: String

    var isDone: Bool { status == "completed" }
    var isActive: Bool { status == "inProgress" || status == "in_progress" }
}

struct FileChange: Hashable {
    let path: String
    /// add / update / delete
    let kind: String
    let diff: String
    var added: Int
    var removed: Int
}

// MARK: - 审批

struct Approval: Identifiable, Hashable {
    let id: Int
    let itemId: String
    let title: String
    let detail: String
    let isCommand: Bool
    let threadId: String?
    let requestID: String?
    let approvalID: String?
    let requestMethod: String?

    init(id: Int, itemId: String, title: String, detail: String, isCommand: Bool,
         threadId: String? = nil, requestID: String? = nil, approvalID: String? = nil,
         requestMethod: String? = nil) {
        self.id = id
        self.itemId = itemId
        self.title = title
        self.detail = detail
        self.isCommand = isCommand
        self.threadId = threadId
        self.requestID = requestID
        self.approvalID = approvalID
        self.requestMethod = requestMethod
    }

    func decision(accept: Bool) -> String {
        if requestMethod == "execCommandApproval" || requestMethod == "applyPatchApproval" {
            return accept ? "approved" : "abort"
        }
        return accept ? "accept" : "decline"
    }
}


/// 服务端 `status.type` 的取值 → "在跑吗"。
///
/// 只有 `active` 表示在跑（`ThreadStatus::Active { activeFlags }`，
/// 实测跑着的会话 `thread/list` 报 `{"type":"active","activeFlags":[]}`）。
/// 其它是 `notLoaded` / `systemError`。
///
/// 以前这里写的是 `"running" || "inProgress"` —— **服务端从不发这两个值**，
/// 于是列表页永远不显示"正在运行"（只有收到 thread/status/changed 事件
/// 的那一次会短暂亮一下）。三处判断各写一遍就会漂，统一到这里。
enum ThreadStatus {
    static func isRunning(_ raw: String) -> Bool {
        raw == "active" || raw == "running"
    }
}

/// agent 反问用户的一个问题。
///
/// 协议里挂在 `agentMessage.questions` 上：
///   { id, header, question, options: [{ label, description }] }
/// 字段名见过几种写法，解析时按顺序试（见 `Protocol_.questions`）。
struct Question: Hashable, Identifiable {
    let id: String
    let header: String
    let text: String
    /// 可选项。空 = 自由回答（直接在输入框里答）。
    let options: [Option]

    struct Option: Hashable, Identifiable {
        let id: String
        let label: String
        let detail: String
    }
}


enum FileChangeSummary {
    static func text(for changes: [FileChange]) -> String {
        var adds = 0
        var dels = 0
        for c in changes {
            adds += c.added
            dels += c.removed
        }
        return "改动 \(changes.count) 个文件 (+\(adds) / -\(dels))"
    }
}

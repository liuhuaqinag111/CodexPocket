import Foundation

enum WorkspaceTaskStatus: Hashable {
    case running, waitingApproval, waitingInput, idle, notLoaded, systemError, unknown

    init(json: JSONDict?) {
        switch json?.str("type") {
        case "active":
            let flags = json?.strs("activeFlags") ?? []
            self = flags.contains("waitingOnApproval") ? .waitingApproval
                : flags.contains("waitingOnUserInput") ? .waitingInput : .running
        case "idle": self = .idle
        case "notLoaded": self = .notLoaded
        case "systemError": self = .systemError
        default: self = .unknown
        }
    }

    var isRunning: Bool { self == .running }
    var isWaiting: Bool { self == .waitingApproval || self == .waitingInput }

    var label: String {
        switch self {
        case .running: return "运行中"
        case .waitingApproval: return "等待审批"
        case .waitingInput: return "等待输入"
        case .idle: return "空闲"
        case .notLoaded: return "未载入"
        case .systemError: return "运行错误"
        case .unknown: return "状态未知"
        }
    }
}

struct WorkspaceThread: Identifiable, Hashable {
    let id: String
    let title: String
    let cwd: String
    let parentThreadID: String?
    let nickname: String?
    let role: String?
    let status: WorkspaceTaskStatus
    let updatedAt: Date?
    let isAgent: Bool
    let isArchived: Bool

    init?(json: JSONDict, archived: Bool = false) {
        guard let id = json.str("id"), !id.isEmpty else { return nil }
        let spawn = json.dict("source")?.dict("subAgent")?.dict("thread_spawn")
        self.id = id
        self.cwd = json.str("cwd") ?? ""
        self.parentThreadID = json.str("parentThreadId") ?? spawn?.str("parent_thread_id")
        self.nickname = json.str("agentNickname") ?? spawn?.str("agent_nickname")
        self.role = json.str("agentRole") ?? spawn?.str("agent_role")
        let name = json.str("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = json.str("preview")?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = [name, nickname, preview].compactMap { $0 }.first { !$0.isEmpty } ?? id
        self.status = WorkspaceTaskStatus(json: json.dict("status"))
        self.updatedAt = json.dbl("updatedAt").map { Date(timeIntervalSince1970: $0) }
        self.isAgent = parentThreadID != nil || json.dict("source")?["subAgent"] != nil
        self.isArchived = archived
    }
}

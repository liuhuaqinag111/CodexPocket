import SwiftUI

/// 一个工具调用的"种类" —— 决定图标、标题、正文怎么摆。
///
/// 之前所有工具都是一坨 JSON：`part("参数", args)`。用户看不出这是
/// 读了文件、改了文件、还是在跑命令。这里按工具名归类，每类给专门的形状。
enum ToolKind {
    case read, edit, write, search, run, task, todo, mcp, other

    /// 从工具名（和各家的命名习惯）判类。
    static func of(_ tool: String, server: String) -> ToolKind {
        let t = tool.lowercased()
        if server.isEmpty, t.isEmpty { return .other }
        if t.contains("read") || t.contains("cat") || t == "view" { return .read }
        if t.contains("edit") || t.contains("patch") || t.contains("apply") { return .edit }
        if t.contains("write") || t.contains("create_file") || t == "new" { return .write }
        if t.contains("grep") || t.contains("search") || t.contains("find")
            || t.contains("glob") || t.contains("ls") { return .search }
        if t.contains("bash") || t.contains("shell") || t.contains("exec")
            || t.contains("terminal") || t.contains("run") { return .run }
        if t.contains("task") || t.contains("agent") || t.contains("dispatch") { return .task }
        if t.contains("todo") || t.contains("plan") { return .todo }
        return .mcp
    }

    var icon: String {
        switch self {
        case .read: return "doc.text.magnifyingglass"
        case .edit: return "square.and.pencil"
        case .write: return "doc.badge.plus"
        case .search: return "magnifyingglass"
        case .run: return "terminal"
        case .task: return "person.2"
        case .todo: return "checklist"
        case .mcp: return "puzzlepiece.extension"
        case .other: return "wrench.and.screwdriver"
        }
    }

    var noun: String {
        switch self {
        case .read: return "读文件"
        case .edit: return "改文件"
        case .write: return "写文件"
        case .search: return "查找"
        case .run: return "运行"
        case .task: return "子任务"
        case .todo: return "待办"
        case .mcp: return "工具"
        case .other: return "调用"
        }
    }

    /// 这个类别的正文要不要按代码排版。
    var mono: Bool {
        switch self {
        case .run, .read, .edit, .write, .search: return true
        case .task, .todo, .mcp, .other: return false
        }
    }
}

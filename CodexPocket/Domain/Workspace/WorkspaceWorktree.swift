import Foundation

struct WorkspaceWorktree: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var head = ""
    var branch: String?
    var isBare = false
    var isDetached = false
    var lockedReason: String?
    var prunableReason: String?
}

enum WorkspaceError: LocalizedError {
    case invalidResponse
    case paginationLoop
    case missingDirectory
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid workspace response."
        case .paginationLoop: return "The server repeated a pagination cursor."
        case .missingDirectory: return "No working directory is selected."
        case .commandFailed(let detail): return detail
        }
    }
}

enum WorkspaceWorktreeParser {
    static func parse(_ output: String) throws -> [WorkspaceWorktree] {
        guard !output.isEmpty else { return [] }
        guard output.hasSuffix("\u{0}\u{0}") else { throw WorkspaceError.invalidResponse }
        var trees: [WorkspaceWorktree] = []
        var current: WorkspaceWorktree?
        for field in output.components(separatedBy: "\u{0}") {
            if field.isEmpty {
                if let tree = current { trees.append(tree) }
                current = nil
            } else if field.hasPrefix("worktree ") {
                guard current == nil else { throw WorkspaceError.invalidResponse }
                let path = String(field.dropFirst(9))
                guard !path.isEmpty else { throw WorkspaceError.invalidResponse }
                current = WorkspaceWorktree(path: path)
            } else {
                guard current != nil else { throw WorkspaceError.invalidResponse }
                apply(field, to: &current!)
            }
        }
        return trees
    }

    private static func apply(_ field: String, to tree: inout WorkspaceWorktree) {
        if field.hasPrefix("HEAD ") {
            tree.head = String(field.dropFirst(5))
        } else if field.hasPrefix("branch ") {
            let ref = String(field.dropFirst(7))
            tree.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
        } else if field == "bare" {
            tree.isBare = true
        } else if field == "detached" {
            tree.isDetached = true
        } else if field == "locked" || field.hasPrefix("locked ") {
            tree.lockedReason = String(field.dropFirst(min(7, field.count)))
        } else if field == "prunable" || field.hasPrefix("prunable ") {
            tree.prunableReason = String(field.dropFirst(min(9, field.count)))
        }
    }
}

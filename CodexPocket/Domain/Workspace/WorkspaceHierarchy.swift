import Foundation

struct WorkspaceAgentRow: Identifiable, Hashable {
    var id: String { thread.id }
    let thread: WorkspaceThread
    let depth: Int
    let childCount: Int
}

enum WorkspaceHierarchy {
    static func rows(from threads: [WorkspaceThread]) -> [WorkspaceAgentRow] {
        var unique: [String: WorkspaceThread] = [:]
        threads.forEach { unique[$0.id] = $0 }
        let ordered = unique.values.sorted { $0.id < $1.id }
        let children = Dictionary(grouping: ordered.filter { $0.parentThreadID != nil }, by: { $0.parentThreadID! })
        var visited = Set<String>()
        var result: [WorkspaceAgentRow] = []
        func visit(_ thread: WorkspaceThread, depth: Int) {
            guard visited.insert(thread.id).inserted else { return }
            let descendants = children[thread.id] ?? []
            result.append(WorkspaceAgentRow(thread: thread, depth: depth, childCount: descendants.count))
            descendants.forEach { visit($0, depth: depth + 1) }
        }
        ordered.filter { $0.parentThreadID == nil || unique[$0.parentThreadID!] == nil }
            .forEach { visit($0, depth: 0) }
        ordered.forEach { visit($0, depth: 0) }
        return result
    }
}

struct WorkspaceWorktreeGroup: Identifiable, Hashable {
    var id: String { worktree.id }
    let worktree: WorkspaceWorktree
    let threads: [WorkspaceThread]

    static func associate(trees: [WorkspaceWorktree], threads: [WorkspaceThread]) -> [Self] {
        let sortedTrees = trees.sorted { $0.path.count > $1.path.count }
        var associations: [String: [WorkspaceThread]] = [:]
        for thread in threads {
            guard let owner = sortedTrees.first(where: { contains(thread.cwd, in: $0.path) }) else { continue }
            associations[owner.id, default: []].append(thread)
        }
        return trees.map { tree in
            let chats = (associations[tree.id] ?? []).sorted {
                ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
            }
            return Self(worktree: tree, threads: chats)
        }
    }

    static func contains(_ cwd: String, in root: String) -> Bool {
        guard !cwd.isEmpty, !root.isEmpty else { return false }
        let directory = (cwd as NSString).standardizingPath
        let base = (root as NSString).standardizingPath
        return directory == base || directory.hasPrefix(base == "/" ? base : base + "/")
    }
}

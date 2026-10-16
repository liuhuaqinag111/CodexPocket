import Foundation

@MainActor
protocol WorkspaceRepositoryProtocol: AnyObject {
    func agents(threadID: String?) async throws -> [WorkspaceThread]
    func threads() async throws -> [WorkspaceThread]
    func worktrees(cwd: String) async throws -> [WorkspaceWorktree]
}

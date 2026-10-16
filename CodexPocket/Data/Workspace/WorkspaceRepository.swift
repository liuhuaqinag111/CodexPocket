import Foundation

@MainActor
final class WorkspaceRepository: WorkspaceRepositoryProtocol {
    private let transport: RPCTransport

    init(transport: RPCTransport) { self.transport = transport }

    private static let agentSources = ["subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther"]
    private static let allSources = ["cli", "vscode", "exec", "appServer", "unknown"] + agentSources

    func agents(threadID: String?) async throws -> [WorkspaceThread] {
        var result: [WorkspaceThread] = []
        var filters: JSONDict = ["sourceKinds": Self.agentSources]
        if let threadID = threadID, !threadID.isEmpty {
            let response = try await request("thread/read", ["threadId": threadID, "includeTurns": false])
            guard let raw = response.dict("thread"), let root = WorkspaceThread(json: raw) else {
                throw WorkspaceError.invalidResponse
            }
            result.append(root)
            filters["ancestorThreadId"] = threadID
        }
        result += try await list(filters: filters)
        return deduplicate(result)
    }

    private func deduplicate(_ threads: [WorkspaceThread]) -> [WorkspaceThread] {
        var unique: [String: WorkspaceThread] = [:]
        var ids: [String] = []
        for thread in threads {
            if unique[thread.id] == nil { ids.append(thread.id) }
            unique[thread.id] = thread
        }
        return ids.compactMap { unique[$0] }
    }

    func threads() async throws -> [WorkspaceThread] {
        try await list(filters: ["sourceKinds": Self.allSources])
    }
    func worktrees(cwd: String) async throws -> [WorkspaceWorktree] {
        guard !cwd.isEmpty else { throw WorkspaceError.missingDirectory }
        let response = try await request("command/exec", [
            "command": ["git", "worktree", "list", "--porcelain", "-z"],
            "cwd": cwd, "timeoutMs": 10000, "disableOutputCap": true,
            "sandboxPolicy": ["type": "readOnly", "networkAccess": false]
        ])
        guard let exitCode = response.int("exitCode"), let stdout = response.str("stdout"),
              let stderr = response.str("stderr") else { throw WorkspaceError.invalidResponse }
        guard exitCode == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorkspaceError.commandFailed(detail.isEmpty ? "Git exited with code \(exitCode)." : detail)
        }
        return try WorkspaceWorktreeParser.parse(stdout)
    }

    private func request(_ method: String, _ params: JSONDict) async throws -> JSONDict {
        try Task.checkCancellation()
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            _ = transport.rpc(method, params, done: { continuation.resume(with: $0) })
        }
        try Task.checkCancellation()
        guard let result = value as? JSONDict else { throw WorkspaceError.invalidResponse }
        return result
    }

    private func list(filters: JSONDict) async throws -> [WorkspaceThread] {
        var result: [WorkspaceThread] = []
        for archived in [false, true] {
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var params = filters
                params["archived"] = archived
                params["limit"] = 100
                params["sortKey"] = "updated_at"
                if let cursor = cursor { params["cursor"] = cursor }
                let response = try await request("thread/list", params)
                guard let values = response.arr("data") else { throw WorkspaceError.invalidResponse }
                for value in values {
                    guard let raw = value as? JSONDict, let thread = WorkspaceThread(json: raw, archived: archived) else {
                        throw WorkspaceError.invalidResponse
                    }
                    result.append(thread)
                }
                cursor = response.str("nextCursor")
                if let cursor = cursor, !seen.insert(cursor).inserted { throw WorkspaceError.paginationLoop }
            } while cursor != nil
        }
        return deduplicate(result)
    }
}

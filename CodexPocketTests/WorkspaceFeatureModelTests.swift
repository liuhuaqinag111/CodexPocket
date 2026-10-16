import XCTest
@testable import CodexPocket

@MainActor
final class WorkspaceRepositoryStub: WorkspaceRepositoryProtocol {
    var agentWaiters: [CheckedContinuation<[WorkspaceThread], Error>] = []
    var treeWaiters: [CheckedContinuation<[WorkspaceWorktree], Error>] = []
    var threadResult: Result<[WorkspaceThread], Error> = .success([])

    func agents(threadID: String?) async throws -> [WorkspaceThread] {
        try await withCheckedThrowingContinuation { agentWaiters.append($0) }
    }
    func threads() async throws -> [WorkspaceThread] { try threadResult.get() }
    func worktrees(cwd: String) async throws -> [WorkspaceWorktree] {
        try await withCheckedThrowingContinuation { treeWaiters.append($0) }
    }
}

final class WorkspaceFeatureModelTests: XCTestCase {
    @MainActor
    func testChangingWorktreeDirectoryClearsPreviousGroupsOnFailure() async {
        let repository = WorkspaceRepositoryStub()
        let model = WorktreesFeatureModel(repository: repository)
        let first = Task { await model.refresh(cwd: "/old") }
        await waitUntil { repository.treeWaiters.count == 1 }
        repository.treeWaiters[0].resume(returning: [WorkspaceWorktree(path: "/old")])
        await first.value
        let second = Task { await model.refresh(cwd: "/new") }
        await waitUntil { repository.treeWaiters.count == 2 }
        repository.treeWaiters[1].resume(throwing: WorkspaceError.invalidResponse)
        await second.value
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertFalse(model.didLoad)
        XCTAssertNotNil(model.errorMessage)
    }
    @MainActor
    func testChangingAgentScopeClearsPreviousRowsEvenIfNewLoadFails() async throws {
        let repository = WorkspaceRepositoryStub()
        let model = AgentsFeatureModel(repository: repository)
        let first = Task { await model.refresh(threadID: "old") }
        await waitUntil { repository.agentWaiters.count == 1 }
        repository.agentWaiters[0].resume(returning: [try XCTUnwrap(WorkspaceThread(json: ["id": "old"]))])
        await first.value
        let second = Task { await model.refresh(threadID: "new") }
        await waitUntil { repository.agentWaiters.count == 2 }
        repository.agentWaiters[1].resume(throwing: WorkspaceError.invalidResponse)
        await second.value
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.didLoad)
        XCTAssertNotNil(model.errorMessage)
    }
    @MainActor
    func testGitTreesRemainVisibleWhenChatListingFails() async {
        let repository = WorkspaceRepositoryStub()
        repository.threadResult = .failure(WorkspaceError.commandFailed("chat listing unavailable"))
        let model = WorktreesFeatureModel(repository: repository)
        let task = Task { await model.refresh(cwd: "/repo") }
        await waitUntil { repository.treeWaiters.count == 1 }
        guard let waiter = repository.treeWaiters.first else { task.cancel(); return }
        waiter.resume(returning: [WorkspaceWorktree(path: "/repo")])
        await task.value
        XCTAssertEqual(model.groups.map(\.id), ["/repo"])
        XCTAssertNotNil(model.chatErrorMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.chatsLoaded)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testAgentFailureIsVisibleAndSuccessfulEmptyResponseIsDistinct() async {
        let repository = WorkspaceRepositoryStub()
        let model = AgentsFeatureModel(repository: repository)
        let task = Task { await model.refresh(threadID: nil) }
        await waitUntil { repository.agentWaiters.count == 1 }
        guard let waiter = repository.agentWaiters.first else { task.cancel(); return }
        waiter.resume(throwing: WorkspaceError.commandFailed("offline"))
        await task.value
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.didLoad)
    }
    @MainActor
    func testLatestAgentRefreshWinsOverLateResponse() async throws {
        let repository = WorkspaceRepositoryStub()
        let model = AgentsFeatureModel(repository: repository)
        let old = Task { await model.refresh(threadID: "old") }
        await waitUntil { repository.agentWaiters.count == 1 }
        let new = Task { await model.refresh(threadID: "new") }
        await waitUntil { repository.agentWaiters.count == 2 }
        let latest = try XCTUnwrap(WorkspaceThread(json: ["id": "new", "cwd": "/repo"]))
        guard repository.agentWaiters.count == 2 else { old.cancel(); new.cancel(); return }
        repository.agentWaiters[1].resume(returning: [latest])
        await new.value
        repository.agentWaiters[0].resume(returning: [])
        await old.value
        XCTAssertEqual(model.rows.map(\.id), ["new"])
        XCTAssertTrue(model.didLoad)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Repository request was not started")
    }
}

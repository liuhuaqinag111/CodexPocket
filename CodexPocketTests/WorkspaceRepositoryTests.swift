import XCTest
@testable import CodexPocket

final class WorkspaceRPCSpy: RPCTransport {
    var calls: [(String, JSONDict)] = []
    var responses: [Result<Any, Error>] = []

    func rpc(_ method: String, _ params: JSONDict,
             done: ((Result<Any, Error>) -> Void)?) -> Int {
        calls.append((method, params))
        done?(responses.isEmpty ? .failure(WorkspaceError.invalidResponse) : responses.removeFirst())
        return calls.count
    }
}

final class WorkspaceRepositoryTests: XCTestCase {
    @MainActor
    func testCommandFailureNeverProducesSyntheticWorktrees() async {
        let spy = WorkspaceRPCSpy()
        let response: JSONDict = ["exitCode": 128, "stdout": "", "stderr": "fatal: not a git repository"]
        spy.responses = [.success(response)]
        do {
            _ = try await WorkspaceRepository(transport: spy).worktrees(cwd: "/not-git")
            XCTFail("Git failure must be surfaced")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a git repository"))
        }
    }

    @MainActor
    func testMalformedListResponseFailsInsteadOfShowingEmpty() async {
        let spy = WorkspaceRPCSpy()
        spy.responses = [.success(["unexpected": "payload"])]
        do {
            _ = try await WorkspaceRepository(transport: spy).threads()
            XCTFail("Missing data must not mean an empty workspace")
        } catch {
            XCTAssertEqual(spy.calls.count, 1)
        }
    }
    @MainActor
    func testRepeatedCursorFailsInsteadOfLoopingForever() async {
        let spy = WorkspaceRPCSpy()
        spy.responses = [.success(page([row("a")], cursor: "repeat")),
            .success(page([row("b")], cursor: "repeat"))]
        do {
            _ = try await WorkspaceRepository(transport: spy).threads()
            XCTFail("A repeated cursor must fail")
        } catch {
            XCTAssertEqual(spy.calls.count, 2)
        }
    }

    @MainActor
    func testWorktreesExecuteBufferedReadOnlyGitWithArgv() async throws {
        let spy = WorkspaceRPCSpy()
        spy.responses = [.success(["exitCode": 0,
            "stdout": "worktree /repo\u{0}HEAD abc\u{0}branch refs/heads/main\u{0}\u{0}", "stderr": ""])]
        let trees = try await WorkspaceRepository(transport: spy).worktrees(cwd: "/repo with spaces")
        XCTAssertEqual(trees.count, 1)
        XCTAssertEqual(spy.calls.first?.0, "command/exec")
        let params = try XCTUnwrap(spy.calls.first?.1)
        XCTAssertEqual(params.strs("command"), ["git", "worktree", "list", "--porcelain", "-z"])
        XCTAssertEqual(params.dict("sandboxPolicy")?.str("type"), "readOnly")
        XCTAssertEqual(params.str("cwd"), "/repo with spaces")
    }
    @MainActor
    func testAgentPagesIncludeArchivedDescendantsAndDeduplicate() async throws {
        let spy = WorkspaceRPCSpy()
        spy.responses = [.success(["thread": row("root")]),
            .success(page([row("a", parent: "root")], cursor: "next")),
            .success(page([row("a", parent: "root"), row("b", parent: "a")])),
            .success(page([row("archived", parent: "root")]))]
        let threads = try await WorkspaceRepository(transport: spy).agents(threadID: "root")
        XCTAssertEqual(Set(threads.map(\.id)), Set(["root", "a", "b", "archived"]))
        XCTAssertEqual(threads.first { $0.id == "archived" }?.isArchived, true)
        XCTAssertEqual(spy.calls.count, 4)
        guard spy.calls.count == 4 else { return }
        XCTAssertEqual(spy.calls[0].1.bool("includeTurns"), false)
        XCTAssertEqual(spy.calls[1].1.str("ancestorThreadId"), "root")
        XCTAssertEqual(spy.calls[2].1.str("cursor"), "next")
        XCTAssertEqual(spy.calls[3].1.bool("archived"), true)
        XCTAssertTrue(spy.calls[1].1.strs("sourceKinds").contains("subAgentThreadSpawn"))
        XCTAssertFalse(spy.calls.contains { $0.0 == "thread/resume" || $0.0 == "turn/start" })
    }

    private func row(_ id: String, parent: String? = nil) -> JSONDict {
        var json: JSONDict = ["id": id, "cwd": "/repo", "status": ["type": "idle"]]
        if let parent = parent { json["parentThreadId"] = parent }
        return json
    }

    private func page(_ threads: [JSONDict], cursor: String? = nil) -> JSONDict {
        ["data": threads, "nextCursor": cursor as Any? ?? NSNull()]
    }
}

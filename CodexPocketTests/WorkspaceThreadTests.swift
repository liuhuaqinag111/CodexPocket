import XCTest
@testable import CodexPocket

final class WorkspaceThreadTests: XCTestCase {
    func testHierarchyBreaksCyclesWithoutLosingTasks() throws {
        let threads = try [fixture("a", parent: "b"), fixture("b", parent: "a")].map {
            try XCTUnwrap(WorkspaceThread(json: $0))
        }
        XCTAssertEqual(Set(WorkspaceHierarchy.rows(from: threads).map(\.id)), Set(["a", "b"]))
    }

    func testChatAssociationUsesRealTreesAndLongestDirectoryBoundary() throws {
        let trees = [WorkspaceWorktree(path: "/repo/"), WorkspaceWorktree(path: "/repo/nested")]
        let threads = try [fixture("main", cwd: "/repo/src"), fixture("nested", cwd: "/repo/nested/src"),
            fixture("outside", cwd: "/repository"), fixture("fake", cwd: "/tmp/.worktrees/fake")].map {
                try XCTUnwrap(WorkspaceThread(json: $0))
            }
        let groups = WorkspaceWorktreeGroup.associate(trees: trees, threads: threads)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(try XCTUnwrap(groups.first).threads.map(\.id), ["main"])
        XCTAssertEqual(try XCTUnwrap(groups.last).threads.map(\.id), ["nested"])
    }
    func testHierarchyOrdersParentsBeforeChildrenAndRetainsOrphans() throws {
        let threads = try [fixture("grand", parent: "child"), fixture("child", parent: "root"),
            fixture("orphan", parent: "missing"), fixture("root")].map {
                try XCTUnwrap(WorkspaceThread(json: $0))
            }
        let rows = WorkspaceHierarchy.rows(from: threads)
        XCTAssertEqual(Set(rows.map(\.id)), Set(["root", "child", "grand", "orphan"]))
        let rootIndex = try XCTUnwrap(rows.firstIndex { $0.id == "root" })
        XCTAssertEqual(Array(rows[rootIndex...].prefix(3)).map(\.id), ["root", "child", "grand"])
        XCTAssertEqual(rows.first { $0.id == "grand" }?.depth, 2)
        XCTAssertEqual(rows.first { $0.id == "root" }?.childCount, 1)
    }

    private func fixture(_ id: String, parent: String? = nil, cwd: String = "/repo") -> JSONDict {
        var json: JSONDict = ["id": id, "cwd": cwd, "status": ["type": "idle"]]
        if let parent = parent { json["parentThreadId"] = parent }
        return json
    }
    func testActiveFlagsDistinguishWaitingFromRunning() {
        XCTAssertEqual(WorkspaceTaskStatus(json: ["type": "active", "activeFlags": [String]()]), .running)
        XCTAssertEqual(WorkspaceTaskStatus(json: ["type": "active",
            "activeFlags": ["waitingOnApproval"]]), .waitingApproval)
        XCTAssertEqual(WorkspaceTaskStatus(json: ["type": "active",
            "activeFlags": ["waitingOnUserInput"]]), .waitingInput)
        XCTAssertEqual(WorkspaceTaskStatus(json: ["type": "idle"]), .idle)
        XCTAssertEqual(WorkspaceTaskStatus(json: ["type": "systemError"]), .systemError)
    }

    func testDirectParentTakesPriorityAndForkIsNotAnAgent() throws {
        let thread = try XCTUnwrap(WorkspaceThread(json: ["id": "child", "cwd": "/repo",
            "parentThreadId": "direct", "agentNickname": "Owner", "agentRole": "builder",
            "source": ["subAgent": ["thread_spawn": ["parent_thread_id": "old"]]]]))
        XCTAssertEqual(thread.parentThreadID, "direct")
        let fork = try XCTUnwrap(WorkspaceThread(json: ["id": "fork", "cwd": "/repo",
            "forkedFromId": "original", "source": "appServer"]))
        XCTAssertNil(fork.parentThreadID)
        XCTAssertFalse(fork.isAgent)
    }
    func testThreadUsesSpawnMetadataNotForkMetadata() throws {
        let json: JSONDict = ["id": "child", "cwd": "/repo", "forkedFromId": "fork",
            "source": ["subAgent": ["thread_spawn": ["parent_thread_id": "parent",
                "agent_nickname": "Scout", "agent_role": "reviewer"]]],
            "status": ["type": "notLoaded"]]
        let thread = try XCTUnwrap(WorkspaceThread(json: json))
        XCTAssertEqual(thread.parentThreadID, "parent")
        XCTAssertEqual(thread.nickname, "Scout")
        XCTAssertEqual(thread.role, "reviewer")
        XCTAssertEqual(thread.status, .notLoaded)
        XCTAssertTrue(thread.isAgent)
    }

    func testMissingStatusIsNotCompletedOrIdle() throws {
        let thread = try XCTUnwrap(WorkspaceThread(json: ["id": "root", "cwd": "/repo"]))
        XCTAssertEqual(thread.status, .unknown)
        XCTAssertFalse(thread.status.isRunning)
    }
}

import XCTest
@testable import CodexPocket

private final class ThreadPageTransport: RPCTransport {
    var calls: [JSONDict] = []
    var pages: [JSONDict] = []
    var deferred = false
    var replies: [RepositoryResult] = []
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        calls.append(params)
        if method == "bridge/provider/models" {
            done?(.success(["available": false, "models": []] as JSONDict))
            return calls.count
        }
        if deferred {
            if let done { replies.append(done) }
            return calls.count
        }
        let page: JSONDict = pages.isEmpty ? ["data": []] : pages.removeFirst()
        done?(.success(page))
        return calls.count
    }
}

@MainActor
final class ThreadListProtocolTests: XCTestCase {
    func testSupersededFullListStopsBeforeRequestingAnotherPage() async {
        let rpc = ThreadPageTransport()
        rpc.deferred = true
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        list.fetchThreads()
        list.fetchThreads()
        rpc.replies[0](.success(["data": [["id": "stale"]], "nextCursor": "stale-next"] as JSONDict))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(rpc.calls.count, 2, "过期的完整读取不能继续翻页")
        rpc.replies[1](.success(["data": [["id": "latest"]]] as JSONDict))
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(list.threads.map(\.id), ["latest"])
    }

    func testFirstPageReconcileCannotInterruptFullList() async {
        for archived in [false, true] {
            let rpc = ThreadPageTransport()
            rpc.deferred = true
            let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
            if archived { list.fetchArchived(); list.fetchArchivedFirstPage() }
            else { list.fetchThreads(); list.fetchThreadsFirstPage() }
            XCTAssertEqual(rpc.calls.count, 1)
            rpc.replies[0](.success(["data": [["id": "first"]], "nextCursor": "more"] as JSONDict))
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(rpc.calls.count, 2)
            rpc.replies[1](.success(["data": [["id": "old"]]] as JSONDict))
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual((archived ? list.archived : list.threads).map(\.id), ["first", "old"])
            XCTAssertNil(archived ? list.archivedFullReadSeq : list.activeFullReadSeq)
        }
    }

    func testFullActiveListKeepsRowsBeyondEightPages() async {
        let rpc = ThreadPageTransport()
        rpc.pages = (0..<9).map { page in
            var payload: JSONDict = ["data": (0..<100).map {
                ["id": "active-\(page * 100 + $0)"]
            }]
            if page < 8 { payload["nextCursor"] = "page-\(page + 1)" }
            return payload
        }
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        list.threads = [Thread(json: ["id": "active-899"])!]
        list.fetchThreads()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(list.threads.count, 900)
        XCTAssertTrue(list.threads.contains { $0.id == "active-899" }, "刷新不能丢掉第801条以后的旧会话")
        XCTAssertEqual(rpc.calls.last?.str("cursor"), "page-8")
    }

    func testFullArchivedListKeepsRowsBeyondEightPages() async {
        let rpc = ThreadPageTransport()
        rpc.pages = (0..<9).map { page in
            var payload: JSONDict = ["data": (0..<100).map {
                ["id": "archived-\(page * 100 + $0)"]
            }]
            if page < 8 { payload["nextCursor"] = "page-\(page + 1)" }
            return payload
        }
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        list.archived = [Thread(json: ["id": "archived-899"])!]
        list.fetchArchived()
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(list.archived.count, 900)
        XCTAssertTrue(list.archived.contains { $0.id == "archived-899" })
        XCTAssertTrue(rpc.calls.allSatisfy { $0["archived"] as? Bool == true })
    }

    func testProjectAndModelCatalogsFollowNextCursor() async {
        for models in [false, true] {
            let rpc = ThreadPageTransport()
            rpc.pages = [["data": [["id": "one"]], "nextCursor": "more"], ["data": [["id": "two"]]]]
            let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
            if models { list.loadModels() } else { list.loadProjects() }
            for _ in 0..<30 { await Task.yield() }
            XCTAssertEqual(models ? list.models.map(\.id) : list.projects.map(\.id), ["one", "two"])
            XCTAssertEqual(rpc.calls.last?.str("cursor"), "more")
        }
    }
    func testDirectoryFallbackUsesLongestActualMatchingRoot() {
        let list = ThreadListModel(repository: ThreadRepository(transport: ThreadPageTransport()), settings: PreferencesModel())
        list.filed = [:]
        let parent = Project(json: ["id": "parent", "roots": ["/repo", "/other/very/long/root"]])!
        let child = Project(json: ["id": "child", "roots": ["/repo/sub"]])!
        let row = Thread(json: ["id": "nested", "cwd": "/repo/sub/src"])!
        for projects in [[parent, child], [child, parent]] {
            list.projects = projects
            XCTAssertEqual(list.project(of: row)?.id, "child")
        }
        let legacy = Thread(json: ["id": "legacy", "cwd": "/repo/sub", "projectId": NSNull()])!
        XCTAssertEqual(list.project(of: legacy)?.id, "child")
    }
    func testMalformedPagePreservesExistingRowsAndReportsError() async {
        let rpc = ThreadPageTransport(); rpc.pages = [["unexpected": true]]
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        list.threads = [Thread(json: ["id": "keep"])!]
        list.fetchThreads()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(list.threads.map(\.id), ["keep"])
        XCTAssertNotNil(list.banner)
    }

    func testRepeatedCursorPreservesExistingRowsAndReportsError() async {
        let rpc = ThreadPageTransport()
        rpc.pages = [["data": [["id": "one"]], "nextCursor": "repeat"],
            ["data": [["id": "two"]], "nextCursor": "repeat"]]
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        list.threads = [Thread(json: ["id": "keep"])!]
        list.fetchThreads()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(list.threads.map(\.id), ["keep"])
        XCTAssertEqual(rpc.calls.count, 2)
        XCTAssertNotNil(list.banner)
    }
    func testEmptyPageWithCursorContinuesInUpdatedOrder() async {
        let rpc = ThreadPageTransport()
        rpc.pages = [["data": [], "nextCursor": "next"], ["data": [["id": "old-active"]]]]
        let list = ThreadListModel(repository: ThreadRepository(transport: rpc), settings: PreferencesModel())
        list.fetchThreads()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(list.threads.map(\.id), ["old-active"])
        XCTAssertEqual(rpc.calls.count, 2)
        XCTAssertTrue(rpc.calls.allSatisfy { $0.str("sortKey") == "updated_at" })
    }
}

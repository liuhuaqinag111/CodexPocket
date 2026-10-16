import XCTest
@testable import CodexPocket

private final class MutationIdentityTransport: RPCTransport {
    var connectionIdentity = "old-account"
    var reply: RepositoryResult?
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        reply = done
        return 1
    }
}

@MainActor
final class ThreadManagementTests: XCTestCase {
    func testSwitchingConversationDoesNotReorderOrExpandProjectGroups() {
        let settings = PreferencesModel()
        settings.openProjects = []; settings.closedProjects = []
        let model = ThreadListModel(repository: ThreadRepository(transport: RecordingTransport()), settings: settings)
        let projects = ["a", "b"].map { Project(json: ["id": $0, "name": $0, "roots": []])! }
        let row = Thread(json: ["id": "chat-b", "projectId": "b"])!
        model.inject(threads: [row], projects: projects)
        let before = model.groups.map(\.id)
        model.currentID = row.id
        XCTAssertEqual(model.groups.map(\.id), before)
        XCTAssertFalse(model.isOpen(model.groups.first { $0.id == "b" }!))
    }

    private func fixture(projectID: String? = nil) -> (ThreadListModel, RecordingTransport, CodexPocket.Thread, Project) {
        let transport = RecordingTransport()
        var json: JSONDict = ["id":"management", "name":"Original", "cwd":"/repo"]
        if let projectID { json["projectId"] = projectID }
        let thread = Thread(json: json)!
        let project = Project(json: ["id":"p", "name":"Project", "roots":[["path":"/repo"]]])!
        let model = ThreadListModel(repository: ThreadRepository(transport: transport), settings: PreferencesModel())
        model.filed = [:]
        model.inject(threads: [thread], projects: [project])
        return (model, transport, thread, project)
    }
    private func settle() async { for _ in 0..<12 { await Task.yield() } }

    func testLateRenameCannotChangeAnotherAccountAtSameURL() async {
        let wire = MutationIdentityTransport()
        let model = ThreadListModel(repository: ThreadRepository(transport: wire), settings: PreferencesModel())
        let row = Thread(json: ["id": "same", "name": "Original"])!
        model.inject(threads: [row])
        model.rename(row, to: "Old rename")
        let reply = wire.reply
        wire.connectionIdentity = "new-account"
        reply?(.success([:] as JSONDict))
        await settle()
        XCTAssertEqual(model.threads, [row])
    }

    func testLateMutationCallbacksCannotChangeAnotherServer() async {
        for operation in ["delete", "move", "unfile", "archive", "rename"] {
            let wire = RecordingTransport(); wire.deferResponse = true
            let store = AppCoordinator(transport: wire)
            let old = Thread(json: ["id": "shared", "name": "Old", "projectId": "old"])!
            let project = Project(json: ["id": "target", "name": "Target", "roots": []])!
            store.list.inject(threads: [old], projects: [project])
            switch operation {
            case "delete": store.list.delete(old)
            case "move": store.list.move(old, to: project)
            case "unfile": store.list.unfile(old)
            case "archive": store.list.archive(old, true)
            default: store.list.rename(old, to: "Renamed")
            }
            let reply = wire.pending
            store.prepareConnection(namespace: "other-server")
            let fresh = Thread(json: ["id": "shared", "name": "New", "projectId": "new"])!
            store.list.inject(threads: [fresh])
            let count = wire.calls.count
            reply?(operation == "rename" ? .success([:] as JSONDict)
                : .failure(RepositoryError(message: "old connection closed")))
            await settle()
            XCTAssertEqual(store.list.threads, [fresh], operation)
            XCTAssertTrue(store.list.archived.isEmpty, operation)
            XCTAssertTrue(store.list.filed.isEmpty, operation)
            XCTAssertNil(store.list.banner, operation)
            XCTAssertEqual(wire.calls.count, count, operation)
            store.chat.close()
        }
    }

    func testNullProjectUsesDirectoryDespiteStaleLocalAssignment() {
        let (model, _, original, project) = fixture()
        let unfiled = Thread(json: ["id": original.id, "cwd": "/repo", "projectId": NSNull()])!
        model.filed[original.id] = "old-project"
        XCTAssertEqual(model.project(of: unfiled)?.id, project.id)
        model.filed.removeValue(forKey: original.id)
        XCTAssertEqual(model.project(of: original)?.id, project.id)
    }

    func testExplicitEmptyProjectStillOverridesDirectory() {
        let (model, _, original, _) = fixture()
        let thread = Thread(json: ["id": original.id, "cwd": "/repo", "projectId": ""])!
        XCTAssertNil(model.project(of: thread))
    }

    func testDesktopProjectlessNullDoesNotFallBackToDirectoryAfterReinstall() {
        let (model, _, original, project) = fixture()
        let row = Thread(json: ["id": original.id, "cwd": "/repo",
            "projectId": NSNull(), "desktopProjectless": true])!
        model.inject(threads: [row])
        XCTAssertTrue(model.filed.isEmpty)
        XCTAssertNil(model.project(of: row))
        XCTAssertEqual(model.recent.map(\.id), [row.id])
        XCTAssertEqual(model.count(in: project), 0)
        XCTAssertTrue(model.groups.first { $0.id == project.id }!.threads.isEmpty)
    }

    func testDesktopProjectlessArchiveStaysIsolatedAfterRestore() {
        let (model, _, _, project) = fixture()
        let row = Thread(json: ["id": "desktop-unfiled", "cwd": "/repo",
            "projectId": NSNull(), "desktopProjectless": true, "archived": true])!
        model.inject(threads: [])
        model.archived = [row]
        XCTAssertEqual(model.count(in: project), 0)
        XCTAssertTrue(model.recent.isEmpty)
        XCTAssertEqual(model.groups.first { $0.isArchive }?.threads.map(\.id), [row.id])
        model.markArchived(row.id, false)
        XCTAssertTrue(model.archived.isEmpty)
        XCTAssertNil(model.project(of: model.threads[0]))
        XCTAssertEqual(model.recent.map(\.id), [row.id])
    }

    func testServerAssignmentAndPhoneMoveOverrideDesktopProjectless() {
        let (model, transport, _, project) = fixture()
        transport.deferResponse = true
        let assigned = Thread(json: ["id": "assigned", "cwd": "/repo",
            "projectId": project.id, "desktopProjectless": true])!
        XCTAssertEqual(model.project(of: assigned)?.id, project.id)
        let row = Thread(json: ["id": "desktop-unfiled", "cwd": "/repo",
            "projectId": NSNull(), "desktopProjectless": true])!
        model.inject(threads: [row])
        XCTAssertNil(model.project(of: row))
        model.move(row, to: project)
        XCTAssertEqual(model.project(of: model.threads[0])?.id, project.id)
        model.unfile(model.threads[0])
        XCTAssertNil(model.project(of: model.threads[0]))
    }

    func testExplicitPhoneUnfileStillOverridesDirectory() {
        let (model, transport, original, _) = fixture()
        transport.deferResponse = true
        let thread = Thread(json: ["id": original.id, "cwd": "/repo", "projectId": NSNull()])!
        model.inject(threads: [thread])
        model.unfile(thread)
        XCTAssertNil(model.project(of: model.threads[0]))
        model.applyThreads([thread], dropPendingMissing: true)
        XCTAssertNil(model.project(of: model.threads[0]))
    }

    func testLegacyProjectSessionsRemainInTheirProjectGroups() {
        let (model, _, _, _) = fixture()
        model.projects = ["竞彩", "知识库"].map {
            Project(json: ["id": $0, "name": $0,
                "roots": [["path": "/tmp/codexpocket-projects/" + $0]]])!
        }
        model.threads = ["竞彩", "竞彩", "知识库", "知识库", "知识库", "知识库", "知识库"]
            .enumerated().map { index, name in
                Thread(json: ["id": "legacy-\(index)", "name": "会话\(index)",
                    "cwd": "/tmp/codexpocket-projects/" + name,
                    "projectId": NSNull()])!
            }
        XCTAssertEqual(model.groups.first { $0.id == "竞彩" }?.threads.count, 2)
        XCTAssertEqual(model.groups.first { $0.id == "知识库" }?.threads.count, 5)
        XCTAssertTrue(model.recent.isEmpty)
    }

    func testMissingProjectMetadataUsesDirectoryForCountAndGroup() {
        let (model, _, _, project) = fixture()
        let rows = ["one", "two"].map {
            Thread(json: ["id": $0, "cwd": "/repo"])!
        }
        model.inject(threads: rows)
        model.archived = [Thread(json: ["id": "archived", "cwd": "/repo", "projectId": NSNull()])!]
        XCTAssertEqual(model.count(in: project), 2)
        XCTAssertEqual(model.groups.first { $0.id == project.id }?.threads.map(\.id), ["one", "two"])
        XCTAssertTrue(model.recent.isEmpty)
        XCTAssertEqual(model.archived.count, 1)
    }

    func testExplicitUnknownProjectDoesNotFallBackToAnotherProject() {
        let (model, _, original, _) = fixture()
        let foreign = Thread(json: ["id": original.id, "cwd": "/repo", "projectId": "unknown"])!
        XCTAssertNil(model.project(of: foreign))
    }
    func testFirstPageWithNoCursorRemovesMissingThreads() async {
        let (model, transport, thread, _) = fixture()
        model.archived = [thread]
        transport.result = .success(["data": []] as JSONDict)
        model.fetchThreadsFirstPage()
        model.fetchArchivedFirstPage()
        await settle()
        XCTAssertTrue(model.threads.isEmpty)
        XCTAssertTrue(model.archived.isEmpty)
    }

    func testFirstPageWithCursorKeepsOlderThreads() async {
        let (model, transport, thread, _) = fixture()
        transport.result = .success(["data": [["id": "new"]], "nextCursor": "page2"] as JSONDict)
        model.fetchThreadsFirstPage()
        await settle()
        XCTAssertEqual(model.threads.map(\.id), ["new", thread.id])
    }

    func testReconcileOccasionallyRefreshesOlderPages() async {
        let (model, transport, _, _) = fixture()
        transport.result = .success(["data": [["id": "page"]], "nextCursor": "next"] as JSONDict)
        for _ in 0..<5 { model.reconcile(); await settle() }
        XCTAssertFalse(transport.calls.contains { $0.0 == "thread/list" && $0.1.str("cursor") != nil })
        model.reconcile()
        for _ in 0..<8 { await settle() }
        XCTAssertTrue(transport.calls.contains { $0.0 == "thread/list" && $0.1.str("cursor") != nil })
    }

    func testDeletingNewThreadCannotResurrectFromPendingCache() {
        let (model, transport, thread, _) = fixture()
        transport.deferResponse = true
        model.pendingNew[thread.id] = (thread, Date())
        model.delete(thread)
        model.applyThreads([], dropPendingMissing: true)
        XCTAssertTrue(model.threads.isEmpty)
        XCTAssertNil(model.pendingNew[thread.id])
    }

    func testArchiveFailureRestoresSelectionAndPendingThread() async {
        let (model, transport, thread, _) = fixture()
        model.currentID = thread.id
        model.pendingNew[thread.id] = (thread, Date())
        transport.result = .failure(RepositoryError(message: "offline"))
        model.archive(thread, true)
        XCTAssertEqual(model.archived.first?.archived, true)
        XCTAssertNil(model.pendingNew[thread.id])
        await settle()
        XCTAssertEqual(model.threads.map(\.id), [thread.id])
        XCTAssertTrue(model.archived.isEmpty)
        XCTAssertEqual(model.currentID, thread.id)
        XCTAssertNotNil(model.pendingNew[thread.id])
    }
    func testServerArchiveOrDeleteCannotResurrectPendingNewThread() {
        let (model, _, thread, _) = fixture()
        model.pendingNew[thread.id] = (thread, Date())
        model.markArchived(thread.id, true)
        model.applyThreads([], dropPendingMissing: true)
        XCTAssertTrue(model.threads.isEmpty)
        XCTAssertEqual(model.archived.first?.id, thread.id)
        model.pendingNew[thread.id] = (thread, Date())
        model.dropped(thread.id)
        model.applyThreads([], dropPendingMissing: true)
        XCTAssertTrue(model.threads.isEmpty)
        XCTAssertTrue(model.archived.isEmpty)
    }


    func testRenameUpdatesArchivedThread() async {
        let (model, _, thread, _) = fixture()
        model.__testSeed(threads: [], archived: [thread])
        model.rename(thread, to: "  Renamed  ")
        await settle()
        XCTAssertEqual(model.archived[0].title, "Renamed")
        XCTAssertTrue(model.archived[0].named)
    }
    func testBlankRenameDoesNotSendRequest() {
        let (model, transport, thread, _) = fixture()
        model.rename(thread, to: " \n ")
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(model.threads[0].title, "Original")
    }

    func testPendingThreadKeepsRenameAndProjectAcrossRefresh() {
        let (model, _, thread, project) = fixture()
        model.pendingNew[thread.id] = (thread, Date())
        model.setName(thread.id, "Renamed")
        model.setProject(thread.id, project.id)
        model.applyThreads([], dropPendingMissing: true)
        XCTAssertEqual(model.threads.first?.title, "Renamed")
        XCTAssertEqual(model.threads.first?.projectId, project.id)
    }
    func testOlderListResponseCannotOverwriteNewerList() async {
        let (model, transport, _, _) = fixture()
        transport.deferResponse = true
        model.fetchThreadsFirstPage()
        let older = transport.pending
        model.fetchThreadsFirstPage()
        let newer = transport.pending
        newer?(.success(["data": [["id": "new"]]] as JSONDict))
        await settle()
        older?(.success(["data": [["id": "old"]]] as JSONDict))
        await settle()
        XCTAssertEqual(model.threads.map(\.id), ["new"])
    }

    func testIdleStatusWithoutCompletedTurnDoesNotMarkUnread() {
        let (model, _, thread, _) = fixture()
        model.setRunning(thread.id, false)
        XCTAssertFalse(model.threads[0].unread)
        model.setRunning(thread.id, true)
        model.setRunning(thread.id, false)
        XCTAssertTrue(model.threads[0].unread)
    }

    func testSuccessfulDeleteUsesComputerDeleteOperation() {
        let (model, transport, thread, _) = fixture()
        transport.deferResponse = true
        model.delete(thread)
        XCTAssertTrue(model.threads.isEmpty)
        XCTAssertEqual(transport.calls.first?.0, "thread/delete")
        XCTAssertEqual(transport.calls.first?.1.str("threadId"), thread.id)
    }
    func testFailedMoveRestoresOriginalProject() async {
        let (model, transport, thread, project) = fixture()
        transport.result = .failure(RepositoryError(message: "offline"))
        model.move(thread, to: project)
        await settle()
        XCTAssertNil(model.threads[0].projectId)
        XCTAssertNil(model.filed[thread.id])
        XCTAssertNotNil(model.banner)
    }
    func testFailedRenamePreservesOriginalName() async {
        let (model, transport, thread, _) = fixture()
        transport.result = .failure(RepositoryError(message: "offline"))
        model.rename(thread, to: "Changed")
        await settle()
        XCTAssertEqual(model.threads[0].title, "Original")
        XCTAssertNotNil(model.banner)
    }

    func testRemovingProjectDoesNotReassignByDirectory() async {
        let (model, transport, thread, _) = fixture(projectID: "p")
        transport.deferResponse = true
        model.unfile(thread)
        XCTAssertNil(model.project(of: model.threads[0]))
        XCTAssertEqual(transport.calls.first?.1.str("projectId"), "")
    }
    func testMovingOverridesPreviousServerProjectImmediately() {
        let (model, transport, thread, project) = fixture(projectID: "old")
        let old = Project(json: ["id":"old", "name":"Old", "roots":[]])!
        model.inject(projects: [old, project])
        transport.deferResponse = true
        model.move(thread, to: project)
        XCTAssertEqual(model.project(of: model.threads[0])?.id, "p")
        XCTAssertEqual(model.threads[0].cwd, "/repo")
    }
    func testFailedDeleteRestoresThreadAndSelection() async {
        let (model, transport, thread, _) = fixture()
        model.currentID = thread.id
        transport.result = .failure(RepositoryError(message: "offline"))
        model.delete(thread)
        await settle()
        XCTAssertEqual(model.threads.map(\.id), [thread.id])
        XCTAssertEqual(model.currentID, thread.id)
        XCTAssertNotNil(model.banner)
    }
    func testFailedListFetchPreservesExistingThreads() async {
        let (model, transport, thread, _) = fixture()
        transport.result = .failure(RepositoryError(message: "offline"))
        model.fetchThreads()
        await settle()
        XCTAssertEqual(model.threads.map(\.id), [thread.id])
        XCTAssertNotNil(model.banner)
    }
}

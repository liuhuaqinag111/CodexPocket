import XCTest
@testable import CodexPocket

@MainActor
private final class FilesTestRepository: FileRepositoryProtocol {
    var requestedPaths: [String] = []
    var conflict = false
    var failDirectory = false
    var childName = "main.swift"
    func readDirectory(path: String) async throws -> [FileEntry] {
        requestedPaths.append(path)
        if failDirectory { throw NSError(domain: "Files unavailable", code: 1) }
        let names: [(String, Bool)] = path == "/repo"
            ? [("Sources", true), ("readme.md", false), (".env", false)]
            : [(childName, false)]
        return names.map { FileEntry(name: $0.0, isDir: $0.1, isSymlink: false) }
    }
    func readText(path: String) async throws -> FileDocument {
        FileDocument(path: path, text: "original")
    }
    func saveText(_ document: FileDocument, text: String) async throws -> FileDocument {
        if conflict {
            throw FileRepositoryError.conflict(FileDocument(path: document.path, text: "remote changes"))
        }
        return FileDocument(path: document.path, text: text)
    }
}

@MainActor
final class FilesModelTests: XCTestCase {
    func testWindowsDirectoryNavigationAndBreadcrumbs() async {
        let model = FilesModel(repository: FilesTestRepository(), root: #"C:\Repo\"#)
        model.enterDirectory(#"c:\repo\Sources\Nested"#)
        await settle()
        XCTAssertEqual(model.currentPath, "c:/repo/Sources/Nested")
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["Repo", "Sources", "Nested"])
        model.enterDirectory(#"C:\Repo-Other"#)
        XCTAssertEqual(model.currentPath, "c:/repo/Sources/Nested")
    }

    func testWindowsDriveRootKeepsTheFirstFolderName() async {
        let model = FilesModel(repository: FilesTestRepository(), root: #"C:\"#)
        model.enterDirectory(#"C:\Sources\Child"#)
        await settle()
        XCTAssertEqual(model.breadcrumbs.map(\.path), ["C:/", "C:/Sources", "C:/Sources/Child"])
    }
    func testRefreshReloadsVisibleExpandedSubdirectories() async {
        let repository = FilesTestRepository()
        let model = FilesModel(repository: repository, root: "/repo")
        model.load()
        await settle()
        model.toggleDirectory("/repo/Sources")
        await settle()
        repository.childName = "renamed.swift"
        model.retryDirectory("/repo")
        await settle()
        XCTAssertTrue(model.rows.contains { $0.path == "/repo/Sources/renamed.swift" })
        XCTAssertFalse(model.rows.contains { $0.path == "/repo/Sources/main.swift" })
        XCTAssertEqual(repository.requestedPaths.filter { $0 == "/repo/Sources" }.count, 2)
    }
    func testFailedDirectoryCanRetryWithoutLosingNavigation() async {
        let repository = FilesTestRepository()
        repository.failDirectory = true
        let model = FilesModel(repository: repository, root: "/repo/")
        model.load()
        await settle()
        XCTAssertFalse(model.currentDirectory.isLoading)
        XCTAssertNotNil(model.currentDirectory.error)
        repository.failDirectory = false
        model.retryDirectory("/repo")
        await settle()
        XCTAssertNil(model.currentDirectory.error)
        XCTAssertEqual(model.rows.first?.path, "/repo/Sources")
        model.enterDirectory("/repo/Sources")
        XCTAssertEqual(model.breadcrumbs.map(\.path), ["/repo", "/repo/Sources"])
        model.enterDirectory("/another-repo")
        XCTAssertEqual(model.currentPath, "/repo/Sources")
    }

    func testDirectoriesLoadLazilyAndExpansionReusesChildren() async {
        let repository = FilesTestRepository()
        let model = FilesModel(repository: repository, root: "/repo")
        model.load()
        await settle()
        XCTAssertEqual(model.rows.map(\.path), ["/repo/Sources", "/repo/readme.md"])
        XCTAssertEqual(repository.requestedPaths, ["/repo"])
        model.toggleDirectory("/repo/Sources")
        await settle()
        XCTAssertEqual(model.rows.map(\.path), ["/repo/Sources", "/repo/Sources/main.swift", "/repo/readme.md"])
        model.toggleDirectory("/repo/Sources")
        model.toggleDirectory("/repo/Sources")
        await settle()
        XCTAssertEqual(repository.requestedPaths, ["/repo", "/repo/Sources"])
    }

    func testCloseIsBlockedWhileRemoteVersionIsLoading() async {
        let model = FilesModel(repository: FilesTestRepository(), root: "/repo")
        model.openFile("/repo/readme.md")
        await settle()
        model.acceptRemoteVersion()
        model.requestCloseDocument()
        XCTAssertNotNil(model.document)
        await settle()
    }

    func testUnsavedCloseRequiresExplicitDiscard() async {
        let model = FilesModel(repository: FilesTestRepository(), root: "/repo")
        model.openFile("/repo/readme.md")
        await settle()
        model.draft = "local changes"
        model.requestCloseDocument()
        XCTAssertTrue(model.showDiscardConfirmation)
        XCTAssertEqual(model.document?.path, "/repo/readme.md")
        XCTAssertEqual(model.draft, "local changes")
        model.cancelDiscard()
        XCTAssertTrue(model.hasUnsavedChanges)
        model.requestCloseDocument()
        model.discardAndClose()
        XCTAssertNil(model.document)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSearchAndHiddenFilterPreserveMatchingAncestor() async {
        let model = FilesModel(repository: FilesTestRepository(), root: "/repo")
        model.load()
        await settle()
        model.toggleDirectory("/repo/Sources")
        await settle()
        model.query = "main"
        XCTAssertEqual(model.rows.map(\.path), ["/repo/Sources", "/repo/Sources/main.swift"])
        model.query = ".env"
        XCTAssertTrue(model.rows.isEmpty)
        model.showHidden = true
        XCTAssertEqual(model.rows.map(\.path), ["/repo/.env"])
    }

    func testSaveConflictPreservesDraftAndLoadedBaseline() async {
        let repository = FilesTestRepository()
        repository.conflict = true
        let model = FilesModel(repository: repository, root: "/repo")
        model.openFile("/repo/readme.md")
        await settle()
        model.draft = "local changes"
        model.saveDocument()
        await settle()
        XCTAssertEqual(model.conflict?.text, "remote changes")
        XCTAssertEqual(model.draft, "local changes")
        XCTAssertEqual(model.document?.text, "original")
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }
}

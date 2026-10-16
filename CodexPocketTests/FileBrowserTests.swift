import XCTest
@testable import CodexPocket

/// 文件树 / 预览的数据层。
///
/// 服务端方法（实测抓包）：
///   fs/readDirectory → {"entries":[{"fileName":"cap.js","isDirectory":false,"isFile":true}]}
///   fs/readFile      → {"dataBase64":"…"}
///   fs/getMetadata   → {"isDirectory":…,"isFile":…,"isSymlink":…,"modifiedAtMs":…}
final class FileBrowserTests: XCTestCase {
    func testWindowsJoinAndWorktreeMembership() {
        XCTAssertEqual(FileBrowser.join(#"C:\repo\"#, "a.swift"), "C:/repo/a.swift")
        XCTAssertTrue(WorkspaceWorktreeGroup.contains(#"c:\REPO\child"#, in: "C:/repo"))
        XCTAssertTrue(WorkspaceWorktreeGroup.contains(#"c:\Repo\child"#, in: #"C:\"#))
        XCTAssertFalse(WorkspaceWorktreeGroup.contains("C:/repo-other", in: #"C:\repo"#))
        XCTAssertFalse(WorkspaceWorktreeGroup.contains("/Repo/child", in: "/repo"))
    }

    @MainActor
    func testWindowsProjectsAndFileSearchAcceptDrivePaths() {
        let store = AppCoordinator()
        let project = Project(json: ["id": "windows-project", "name": "Windows",
                                    "roots": [["path": #"C:\Repo"#]]])!
        let thread = Thread(json: ["id": "windows-thread", "name": "Windows",
                                  "cwd": "c:/REPO/app"])!
        store.list.clearFiled()
        store.list.inject(projects: [project])
        store.list.inject(threads: [thread])
        store.list.currentID = thread.id
        XCTAssertTrue(project.owns(thread))
        XCTAssertEqual(store.list.project(of: thread)?.id, project.id)
        XCTAssertEqual(store.composer.fileRoots(), [thread.cwd])
    }

    /// 目录排前面，同类按名字排 —— 否则文件树读起来是乱的。
    func testEntriesSortDirsFirstThenName() {
        let json: JSONDict = ["entries": [
            ["fileName": "z.swift", "isDirectory": false, "isFile": true],
            ["fileName": "beta", "isDirectory": true, "isFile": false],
            ["fileName": "a.swift", "isDirectory": false, "isFile": true],
            ["fileName": "alpha", "isDirectory": true, "isFile": false],
        ]]
        let rows = FileEntry.parse(json)
        XCTAssertEqual(rows.map(\.name), ["alpha", "beta", "a.swift", "z.swift"])
        XCTAssertTrue(rows[0].isDir)
        XCTAssertFalse(rows[2].isDir)
    }

    func testDecodeText() {
        let b64 = Data("let a = 1\n".utf8).base64EncodedString()
        XCTAssertEqual(FileText.decode(["dataBase64": b64]), "let a = 1\n")
    }

    /// 二进制不能当文本渲染 —— 塞进 Text 会卡死并显示乱码。
    func testBinaryIsRejected() {
        let b64 = Data([0x00, 0x01, 0xFF, 0xFE, 0x00]).base64EncodedString()
        XCTAssertNil(FileText.decode(["dataBase64": b64]), "二进制被当成文本了")
    }

    /// 超大文件不能整份读回来 —— 服务端会把整个文件 base64 塞进一条消息。
    func testHugeFileIsRejected() {
        XCTAssertTrue(FileText.isTooLarge(byteCount: 4 * 1024 * 1024))
        XCTAssertFalse(FileText.isTooLarge(byteCount: 100 * 1024))
    }

    /// 路径拼接要处理结尾斜杠，否则会拼出 `//` 或丢掉分隔符。
    func testJoinPath() {
        XCTAssertEqual(FileBrowser.join("/Users/me", "a.swift"), "/Users/me/a.swift")
        XCTAssertEqual(FileBrowser.join("/Users/me/", "a.swift"), "/Users/me/a.swift")
        XCTAssertEqual(FileBrowser.join("/", "etc"), "/etc")
    }
}

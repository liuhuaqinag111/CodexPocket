import XCTest
@testable import CodexPocket

/// 文件改动条目：解析 + 摘要文案。
///
/// 渲染层是 `MessageRow` 里的 `FoldBlock` + `FileDiff`（等宽 diff、增删行带底色），
/// 这里只锁"数据进得来、摘要算得对"——UI 结构变了不该让这两条失败。
final class FileChangesBlockTests: XCTestCase {

    func testFileChangeItemParsing() {
        let raw = [
            "path": "CodexPocket/Core/Usage.swift",
            "kind": "modified",
            "added": 12,
            "removed": 3,
            "diff": "@@ -1,3 +1,12 @@"
        ] as [String: Any]

        let parsed = Protocol_.fileChangesFrom([raw])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.path, "CodexPocket/Core/Usage.swift")
        XCTAssertEqual(parsed.first?.added, 12)
        XCTAssertEqual(parsed.first?.removed, 3)
    }

    func testSummaryTextFormatsCorrectly() {
        let changes = [
            FileChange(path: "a.swift", kind: "added", diff: "", added: 20, removed: 0),
            FileChange(path: "b.swift", kind: "deleted", diff: "", added: 0, removed: 10)
        ]
        XCTAssertEqual(FileChangeSummary.text(for: changes), "改动 2 个文件 (+20 / -10)")
    }
}

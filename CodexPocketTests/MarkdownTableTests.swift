import XCTest
@testable import CodexPocket

final class MarkdownTableTests: XCTestCase {

    func testParseMarkdownTable() {
        let md = """
| 功能 | 状态 | 说明 |
| --- | :---: | ---: |
| 帧级日志 | 完成 | 已打桩 |
| 插话/排队 | 完成 | UI切模式 |
"""
        let blocks = Markdown.parse(md)
        XCTAssertEqual(blocks.count, 1)
        if case .table(let headers, let rows) = blocks[0] {
            XCTAssertEqual(headers, ["功能", "状态", "说明"])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows[0], ["帧级日志", "完成", "已打桩"])
            XCTAssertEqual(rows[1], ["插话/排队", "完成", "UI切模式"])
        } else {
            XCTFail("未能解析为 TableBlock: \(blocks)")
        }
    }

    func testNonTablePipesFallBackToParagraph() {
        let text = "| 这只是一行普通的竖线文本"
        let blocks = Markdown.parse(text)
        XCTAssertEqual(blocks.count, 1)
        if case .paragraph = blocks[0] {
            // pass
        } else {
            XCTFail("不完整的表格应该回退为普通段落: \(blocks)")
        }
    }
}

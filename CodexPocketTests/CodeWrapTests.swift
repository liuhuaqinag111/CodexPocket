import XCTest
import UIKit
@testable import CodexPocket

/// 代码块不许折行。
///
/// 用户截图：`print("hello, world")` 被折成 `print("hell` / `o, world")`。
/// 一行源代码被折行之后没法读（缩进、对齐全乱），也没法整行复制。
///
/// 判据：一行 100 字符的代码，自然高度必须和一行 5 字符的**一样**。
/// 折行了高度就会翻倍。
final class CodeWrapTests: XCTestCase {

    private func attr(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ])
    }

    func testLongLineDoesNotWrap() {
        let short = SelectableText.naturalSize(attr("x = 1"))
        let long = SelectableText.naturalSize(attr("print(\"hello, world, this is a fairly long line of code\")"))
        XCTAssertEqual(long.height, short.height, accuracy: 1.0,
                       "长代码行被折行了（高度 \(long.height) vs 短行 \(short.height)）")
    }

    func testLongLineStaysWide() {
        let short = SelectableText.naturalSize(attr("x = 1"))
        let long = SelectableText.naturalSize(attr(String(repeating: "a", count: 80)))
        XCTAssertGreaterThan(long.width, short.width + 100,
                             "长行的自然宽度没撑开 —— 说明它被按容器宽度折行了")
    }

    func testMultipleLinesReportCorrectHeight() {
        let one = SelectableText.naturalSize(attr("a = 1"))
        let three = SelectableText.naturalSize(attr("a = 1\nb = 2\nc = 3"))
        XCTAssertGreaterThan(three.height, one.height * 2,
                             "三行的高度应该接近一行三倍")
    }

    func testEmptyIsZero() {
        XCTAssertEqual(SelectableText.naturalSize(NSAttributedString(string: "")), .zero)
    }
}

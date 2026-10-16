import XCTest
import UIKit
@testable import CodexPocket

final class QuoteActionTests: XCTestCase {

    func testFormatQuoteTextSingleLine() {
        let q = ComposerModel.formatQuote("这是一条简短回复")
        XCTAssertEqual(q, "> 这是一条简短回复\n\n")
    }

    func testFormatQuoteTextMultiLine() {
        let raw = "第一行\n第二行\n第三行"
        let q = ComposerModel.formatQuote(raw)
        XCTAssertEqual(q, "> 第一行\n> 第二行\n> 第三行\n\n")
    }

    @MainActor
    func testAppendQuoteToComposer() {
        let store = AppCoordinator()
        store.composer.text = "原内容"
        store.composer.appendQuote("引用内容")
        XCTAssertTrue(store.composer.text.contains("> 引用内容"))
        XCTAssertTrue(store.composer.text.contains("原内容"))
    }

    @MainActor
    func testSelectionMenuPreservesCopyAndAddsQuote() throws {
        let view = UITextView()
        view.text = "hello selected world"
        view.selectedRange = NSRange(location: 6, length: 8)
        let coordinator = SelectableText.Coordinator()
        coordinator.quoteSelection = { _ in }
        let copy = UIAction(title: "Copy") { _ in }
        let menu = try XCTUnwrap(coordinator.textView(view,
            editMenuForTextIn: view.selectedRange, suggestedActions: [copy]))
        XCTAssertEqual(menu.children.count, 2)
        XCTAssertEqual((menu.children.first as? UIAction)?.title, "引用")
        XCTAssertTrue(menu.children.last === copy)
    }
}

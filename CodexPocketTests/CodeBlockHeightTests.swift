import XCTest
import SwiftUI
@testable import CodexPocket

/// 代码块塌成 0 高。
///
/// 用户截图里的现象：一段 ```bash 代码块，屏幕上**只看到 "bash / 复制" 那一行**，
/// 下面的代码是空的。原因是 `CodeBlock` 把正文放进**横向 ScrollView**，
/// 而横向 ScrollView 给子视图的宽度提案是 nil ——
/// `SelectableText.sizeThatFits` 拿到 nil 后返回"上一次的尺寸"，
/// 第一次正好是 `.zero`，于是块高 = 0。
final class CodeBlockHeightTests: XCTestCase {

    /// 宽度提案无效时，必须自己用无限宽量出真实高度，不能返回 0。
    @MainActor
    func testFallsBackToIntrinsicSizeWhenWidthUnknown() {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText = NSAttributedString(
            string: "line one\nline two\nline three",
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        let fit = tv.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                         height: CGFloat.greatestFiniteMagnitude))
        XCTAssertGreaterThan(fit.height, 0, "量不出高度 —— 代码块会塌成 0")
        XCTAssertGreaterThan(fit.height, 30, "三行代码至少 30pt 高")
    }

    /// 走 `SelectableText.intrinsic`（宽度未知时真正用的那条路）。
    @MainActor
    func testIntrinsicSizeIsNonZero() {
        let tv = UITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText = NSAttributedString(
            string: "line one\nline two\nline three",
            attributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        let size = SelectableText.intrinsic(tv)
        XCTAssertGreaterThan(size.height, 0, "宽度未知时量出 0 高 —— 代码块会塌掉")
        XCTAssertGreaterThan(size.height, 30, "三行代码至少 30pt 高")
    }
}

import XCTest
import UIKit
@testable import CodexPocket

/// 量一条**真实长回合**（258 条：161 命令 + 92 思考）在各层的成本。
///
/// 样本是 `thread/turns/list` 的真实回包快照，放在 `/tmp/turns.json`。
/// 目的是分清"卡死"到底卡在哪一层：解析 / 分组 / Markdown / CoreText 排版。
final class BigTurnPerfTests: XCTestCase {

    private func sample() -> Any? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/turns.json")),
              let raw = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return raw
    }

    private func ms(_ label: String, _ n: Int = 1, _ f: () -> Void) {
        let t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { f() }
        let e = (CFAbsoluteTimeGetCurrent() - t) * 1000 / Double(n)
        print(String(format: "BIGTURN %@ = %.2f ms", label, e))
    }

    func testParseGroupMarkdownAndLayout() throws {
        guard let raw = sample() else { throw XCTSkip("没有 /tmp/turns.json 样本") }
        var items: [Item] = []
        ms("Protocol_.items(冷)") { items = Protocol_.items(fromTurns: raw) }
        print("BIGTURN items = \(items.count)")
        XCTAssertGreaterThan(items.count, 200)

        ms("Grouping.rows(冷)") { _ = Grouping.rows(items, liveTurnId: nil, gen: Int.random(in: 1...99999)) }

        // 最长的一条思考正文：走一遍 Markdown 渲染。
        let longest = items.compactMap { it -> String? in
            if case .reasoning(_, let t) = it { return t }
            return nil
        }.max(by: { $0.count < $1.count }) ?? ""
        print("BIGTURN 最长思考 = \(longest.count) 字")
        ms("Markdown.body(冷)") {
            _ = Markdown.body(longest, size: 14, color: UIColor.gray)
        }

        // CoreText 排版：`SelectableText.sizeThatFits` 最后落到这一步。
        let a = Markdown.body(longest, size: 14, color: UIColor.gray)
        let width: CGFloat = 358
        ms("boundingRect(排版)") {
            _ = a.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                               context: nil)
        }
        // UITextView 才是真正的路径（它比 boundingRect 贵）。
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.attributedText = a
        ms("UITextView.sizeThatFits") {
            _ = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        }

        // 整组展开：所有成员一次建 UITextView（WorkGroup 展开时的行为）。
        let members = items
        let texts: [NSAttributedString] = members.compactMap { it -> NSAttributedString? in
            switch it {
            case .reasoning(_, let t): return Markdown.body(t, size: 14, color: UIColor.gray)
            case .command(_, let c, let o):
                return NSAttributedString(string: o.isEmpty ? c : o,
                                          attributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            default: return nil
            }
        }
        print("BIGTURN 展开成员 = \(texts.count) 个正文")
        ms("全部 sizeThatFits") {
            for s in texts {
                let v = UITextView()
                v.isScrollEnabled = false
                v.attributedText = s
                _ = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            }
        }
    }
}

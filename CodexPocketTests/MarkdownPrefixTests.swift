import XCTest
@testable import CodexPocket

/// `Markdown.blocks` 的流式前缀复用**必须和整篇解析结果逐块相同**。
///
/// 这条路是为了省流式时的重复排版加的，一旦有偏差，界面上的正文就会
/// 悄悄缺块/错块 —— 所以拿真实样本按流式节奏喂一遍，逐跳比对。
final class MarkdownPrefixTests: XCTestCase {

    private func samples() -> [String] {
        var out: [String] = [
            "第一段。\n\n第二段。\n\n## 标题\n\n- a\n- b\n\n```bash\nls -la\n```\n\n结尾。",
            "只有一段没有空行，一直长下去。",
            "好了。\n\n![结果](</tmp/a b(1).png>)\n\n后面正文",
            "```\ncode\n```\n\n后面\n\n再后面",
            "> 引用\n\n1. 一\n2. 二\n\n| a | b |\n| --- | --- |\n| 1 | 2 |",
        ]
        if let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/turns.json")),
           let raw = try? JSONSerialization.jsonObject(with: d) {
            out.append(contentsOf: Protocol_.items(fromTurns: raw).compactMap { it -> String? in
                switch it {
                case .reasoning(_, let t): return t
                case .agent(_, let t): return t
                default: return nil
                }
            })
        }
        return out.filter { !$0.isEmpty }
    }

    /// 把一份样本按流式节奏（每次 +step 字）喂进去，逐跳和整篇解析比对。
    private func assertStreamingMatches(_ full: String, step: Int,
                                        file: StaticString = #filePath, line: UInt = #line) {
        // 先清掉模块级缓存/记忆格，避免上一个样本的前缀干扰。
        _ = Markdown.blocks("\u{0}reset\u{0}")
        var n = step
        while n < full.count {
            let prefix = String(full.prefix(n))
            let streamed = Markdown.blocks(prefix)
            let plain = Markdown.parse(prefix)
            XCTAssertEqual(streamed.count, plain.count,
                           "第 \(n) 字：块数 \(streamed.count) ≠ \(plain.count)", file: file, line: line)
            for (i, (a, b)) in zip(streamed, plain).enumerated() {
                XCTAssertEqual("\(a)", "\(b)", "第 \(n) 字：第 \(i) 块不一致", file: file, line: line)
            }
            n += step
        }
    }

    func testStreamingPrefixMatchesFullParse() throws {
        // 样本有 130 多份，逐份逐跳要跑 4 分钟。抽 1/5（加上最长的几份）
        // 就足以覆盖边界：短文本、无空行、围栏、表格、引用、列表。
        let all = samples()
        var picked = all.enumerated().filter { $0.offset % 5 == 0 }.map { $0.element }
        picked.append(contentsOf: all.sorted { $0.count > $1.count }.prefix(3))
        for (i, s) in picked.enumerated() {
            assertStreamingMatches(s, step: 37)
            print("MD 样本 \(i) \(s.count) 字：逐跳一致")
        }
    }

    func testLongSampleManySteps() throws {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/turns.json")),
              let raw = try? JSONSerialization.jsonObject(with: d) else {
            throw XCTSkip("没有 /tmp/turns.json 样本")
        }
        let longest = Protocol_.items(fromTurns: raw).compactMap { it -> String? in
            if case .reasoning(_, let t) = it { return t }
            return nil
        }.max(by: { $0.count < $1.count }) ?? ""
        try XCTSkipIf(longest.isEmpty, "样本里没有思考正文")
        assertStreamingMatches(longest, step: 211)
    }
}

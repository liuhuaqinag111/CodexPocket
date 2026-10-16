import XCTest
import UIKit
@testable import CodexPocket

/// 量「流式时正文每 55ms 重排一次」的成本。
///
/// `Markdown.blocks` 按**整份原文**缓存。流式时原文每次都在变（变长），
/// 于是每一轮都是 cache miss，把已经排过的那几千字**从头再排一遍**。
/// 成本随正文长度线性增长 —— 一条 9000 字的思考，单次就要几十毫秒，
/// 而 flush 是 55ms 一轮。
final class StreamMarkdownPerfTests: XCTestCase {

    func testLargeStreamingPrefixesStayWithinCacheCostBudgets() {
        for n in stride(from: 80_000, through: 100_000, by: 1_000) {
            let text = String(repeating: "字", count: n)
            _ = Markdown.blocks(text)
            _ = Markdown.body(text)
        }
        XCTAssertLessThanOrEqual(Markdown.blockCacheCost, Markdown.blockCacheBudget)
        XCTAssertLessThanOrEqual(Markdown.bodyCacheCost, Markdown.bodyCacheBudget)
    }

    private func longestReasoning() -> String {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/turns.json")),
              let raw = try? JSONSerialization.jsonObject(with: d) else { return "" }
        let items = Protocol_.items(fromTurns: raw)
        return items.compactMap { it -> String? in
            if case .reasoning(_, let t) = it { return t }
            return nil
        }.max(by: { $0.count < $1.count }) ?? ""
    }

    func testStreamingMarkdownCost() throws {
        let full = longestReasoning()
        try XCTSkipIf(full.isEmpty, "没有 /tmp/turns.json 样本")
        // 模拟流式：从空开始，按 40 字一跳长到全文，每一跳都排一次版。
        let step = 40
        let steps = stride(from: step, through: full.count, by: step).map { $0 }

        var t = CFAbsoluteTimeGetCurrent()
        for n in steps {
            _ = Markdown.blocks(String(full.prefix(n)))
        }
        let cold = (CFAbsoluteTimeGetCurrent() - t) * 1000

        t = CFAbsoluteTimeGetCurrent()
        for n in steps {
            _ = Markdown.blocks(String(full.prefix(n)))
        }
        let warm = (CFAbsoluteTimeGetCurrent() - t) * 1000

        print("STREAMMD 全文 \(full.count) 字，\(steps.count) 跳")
        print(String(format: "STREAMMD 冷缓存总计 %.1f ms（平均 %.2f ms/跳，最坏 ~%.0f ms）",
                     cold, cold / Double(steps.count), cold / Double(steps.count) * 4))
        print(String(format: "STREAMMD 二次（理论命中）%.1f ms", warm))
        // 真实会话里这个成本决定流式期主线程占用率：13 秒 ~236 跳。
        XCTAssertGreaterThan(cold, 0)
    }
}

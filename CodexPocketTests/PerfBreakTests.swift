import XCTest
@testable import CodexPocket

/// 把 `Grouping.rows` 拆开量，找出到底是哪一段贵。
final class PerfBreakTests: XCTestCase {
    func testManyBreaksKeepTheEarliestTimedBoundaryWithoutQuadraticScan() {
        let user = Item.user(id: "u", text: "hello", images: [])
        let breaks = (0..<5000).map { Item.turnBreak(id: "tb-\($0)", at: Date(), duration: Double($0)) }
        let result = Grouping.normalizeBreaks([user] + breaks)
        XCTAssertEqual(result.map(\.id), ["u", "tb-0"])
    }
    private func realItems() -> [Item] {
        let p = NSHomeDirectory() + "/Library/Caches/chat/00000000-0000-4000-8000-000000000001.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let raw = try? JSONSerialization.jsonObject(with: d) else { return [] }
        return Protocol_.items(fromTurns: raw)
    }

    private func time(_ n: Int, _ label: String, _ f: () -> Void) {
        let t = Date()
        for _ in 0..<n { f() }
        print(String(format: "PERFB %@ %.3f ms/次", label, Date().timeIntervalSince(t) * 1000 / Double(n)))
    }

    /// 命中缓存（滑动期间的常态）必须是微秒级。
    func testCachedRowsIsCheap() throws {
        let items = realItems()
        try XCTSkipIf(items.isEmpty, "无样本")
        let g = 7
        _ = Grouping.rows(items, liveTurnId: nil, gen: g)   // 先铺一次
        time(20, "rows(缓存命中)") { _ = Grouping.rows(items, liveTurnId: nil, gen: g) }
        time(20, "normalizeBreaks") { _ = Grouping.normalizeBreaks(items) }
    }

    /// 冷算一次的真实成本（内容变了才会走到）。
    func testColdRowsCost() throws {
        let items = realItems()
        try XCTSkipIf(items.isEmpty, "无样本")
        let t = Date()
        for i in 0..<10 {
            _ = Grouping.rows(items, liveTurnId: nil, gen: 1000 + i)
        }
        print(String(format: "PERFB rows(冷算) %.3f ms/次", Date().timeIntervalSince(t) * 100))
    }
}

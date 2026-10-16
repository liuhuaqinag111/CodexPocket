import XCTest
import UIKit
@testable import CodexPocket

final class DrawerMotionTests: XCTestCase {
    func testGesturePreviewDoesNotAddInsertionOffset() {
        XCTAssertFalse(RootView.shouldAnimateDrawerInsertion(isDragging: true))
        XCTAssertTrue(RootView.shouldAnimateDrawerInsertion(isDragging: false))
    }
}

private final class TrackingScrollView: UIScrollView {
    var simulatedTracking = false
    override var isTracking: Bool { simulatedTracking }
    var writes: [CGFloat] = []
    override func setContentOffset(_ offset: CGPoint, animated: Bool) {
        writes.append(offset.y)
        super.setContentOffset(offset, animated: animated)
    }
}

@MainActor
final class ScrollSensorTests: XCTestCase {
    func testHistoryPositionSurvivesContentAndViewportChanges() async {
        let (scroll, sensor) = fixture()
        scroll.contentSize.height = 2400
        scroll.bounds.size.height = 300
        await layoutTurn()
        XCTAssertEqual(scroll.contentOffset.y, 500, accuracy: 0.5)
        XCTAssertTrue(sensor.away)
        XCTAssertTrue(scroll.writes.isEmpty)
    }

    func testFollowReportsTheSettledPosition() async {
        let (scroll, sensor) = fixture()
        var metrics: ScrollSensor.Metrics?
        sensor.onScroll = { metrics = $0 }
        sensor.followGen += 1
        await layoutTurn()
        XCTAssertEqual(metrics?.gap, 0)
        XCTAssertEqual(metrics?.atEnd, true)
        XCTAssertEqual(metrics?.offset, scroll.contentOffset.y)
    }

    func testExplicitFollowWaitsUntilTheGestureEnds() async {
        let (scroll, sensor) = fixture()
        scroll.simulatedTracking = true
        sensor.followGen += 1
        scroll.contentSize.height = 2100
        await layoutTurn()
        XCTAssertEqual(scroll.contentOffset.y, 500, accuracy: 0.5)
        scroll.simulatedTracking = false
        scroll.contentSize.height = 2101
        await layoutTurn()
        XCTAssertEqual(scroll.contentOffset.y, 1601, accuracy: 0.5)
    }

    func testFollowRequestDoesNotWaitForSlowPoll() async {
        let (scroll, sensor) = fixture()
        sensor.followGen += 1
        await layoutTurn()
        XCTAssertEqual(scroll.contentOffset.y, 1500, accuracy: 0.5)
        XCTAssertFalse(sensor.away)
    }

    func testViewportResizeFollowsTheFinalBottom() async {
        let (scroll, _) = fixture(away: false)
        scroll.bounds.size.height = 300
        await layoutTurn()
        XCTAssertEqual(scroll.contentOffset.y, 1700, accuracy: 0.5)
    }

    func testLayoutChangesDoNotPinIntermediateHeights() async {
        let (scroll, _) = fixture(away: false)
        scroll.contentSize.height = 2010
        scroll.contentSize.height = 2050
        scroll.contentSize.height = 2100
        XCTAssertEqual(scroll.contentOffset.y, 1500, accuracy: 0.5,
                       "KVO must not move the page inside an unfinished layout")
        await layoutTurn()
        XCTAssertEqual(scroll.contentOffset.y, 1600, accuracy: 0.5)
        XCTAssertEqual(scroll.writes, [1600])
    }

    private func fixture(away: Bool = true) -> (TrackingScrollView, ScrollSensor.SensorView) {
        let scroll = TrackingScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 320, height: 2000)
        scroll.contentOffset.y = away ? 500 : 1500
        let sensor = ScrollSensor.SensorView()
        sensor.away = away
        scroll.addSubview(sensor)
        sensor.attach()
        scroll.writes = []
        return (scroll, sensor)
    }

    private func layoutTurn() async {
        await withCheckedContinuation { done in
            DispatchQueue.main.async { done.resume() }
        }
    }
}

/// 量"每次 body 重算"的开销。
///
/// 用户报「上下滑好卡」。滑动时 `ScrollSensor` 每秒往 @State 写十几次，
/// 每次写都让 `ChatView.body` 重算一遍 —— 里面除了列表还有那串
/// 常驻探针（`orderProbe` 会再跑一次 `Grouping.rows`，`rawProbe`/`tbProbe`
/// 把 200 多条全 map 成字符串）。这份测试把那些开销钉在数字上。
final class PerfProbeTests: XCTestCase {

    /// 真实会话（模拟器缓存）里那份 items。
    private func realItems() -> [Item] {
        let path = NSHomeDirectory() + "/Library/Caches/chat/codexpocket-fixture.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let raw = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return Protocol_.items(fromTurns: raw)
    }

    func testMarkdownBodyCost() throws {
        let items = realItems()
        try XCTSkipIf(items.isEmpty, "没有缓存样本")
        let texts = items.filter { $0.isAgent }.map { $0.text }
        let blocks = texts.flatMap { Markdown.blocks($0) }
        let paras = blocks.compactMap { b -> String? in
            if case .paragraph(let t) = b { return t }
            return nil
        }
        print("PERF blocks=\(blocks.count) 段落=\(paras.count) 段落字数=\(paras.reduce(0) { $0 + $1.count })")
        // 热一次，把 Markdown.blocks 的缓存铺好
        for t in paras { _ = Markdown.body(t) }
        let t0 = Date()
        for _ in 0..<10 { for t in paras { _ = Markdown.body(t) } }
        let ms = Date().timeIntervalSince(t0) * 100
        print("PERF body=\(ms)ms/轮 (\(paras.count) 段)")
        let t1 = Date()
        for _ in 0..<10 { for t in texts { _ = Markdown.blocks(t) } }
        print("PERF blocks=\(Date().timeIntervalSince(t1) * 100)ms/轮 (缓存命中, \(texts.count) 条)")
    }

    func testGroupingRowsCost() throws {
        let items = realItems()
        try XCTSkipIf(items.isEmpty, "没有缓存样本")
        let t0 = Date()
        for _ in 0..<10 {
            _ = Grouping.rows(items, liveTurnId: nil)
        }
        let ms = Date().timeIntervalSince(t0) * 100
        print("PERF items=\(items.count) rows=\(ms)ms/次 文本=\(items.reduce(0) { $0 + $1.text.count })字")
        XCTAssertLessThan(ms, 8, "Grouping.rows 单次超过 8ms，滑动时每秒十几次就是卡顿源")
    }
}

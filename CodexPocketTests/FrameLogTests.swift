import XCTest
@testable import CodexPocket

/// 帧级日志。
///
/// 用户反复报的"看不见回复 / 打开只显示当前输出 / 卡在刚加载进去的"，
/// 每次都要靠猜是**帧没到**还是**到了没画**。这份日志就是为了把这件事
/// 变成一次可定性的排查：FRAME（到了）→ GATE（放行/丢弃）→ RENDER（画上屏）。
final class FrameLogTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FrameLog.clear()
        UserDefaults.standard.set(true, forKey: FrameLog.flagKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(false, forKey: FrameLog.flagKey)
        FrameLog.clear()
        super.tearDown()
    }

    /// 关着的时候一个字都不许写（它挂在每一条事件和每一行的 onAppear 上）。
    func testDisabledWritesNothing() {
        UserDefaults.standard.set(false, forKey: FrameLog.flagKey)
        FrameLog.mark("FRAME", "不该被写进去")
        XCTAssertTrue(FrameLog.read().isEmpty, "关掉还写日志")
    }

    /// 三类标记都要写，而且按调用顺序。
    func testWritesThreeKindsInOrder() {
        FrameLog.mark("FRAME", "item/agentMessage/delta abc")
        FrameLog.mark("GATE", "放行 item/completed")
        FrameLog.mark("RENDER", "abc agent")
        let log = FrameLog.read()
        XCTAssertTrue(log.contains("FRAME item/agentMessage/delta abc"), "缺 FRAME")
        XCTAssertTrue(log.contains("GATE 放行 item/completed"), "缺 GATE")
        XCTAssertTrue(log.contains("RENDER abc agent"), "缺 RENDER")
        guard let f = log.range(of: "FRAME"),
              let g = log.range(of: "GATE"),
              let r = log.range(of: "RENDER") else { return XCTFail("顺序取不到") }
        XCTAssertTrue(f.lowerBound < g.lowerBound && g.lowerBound < r.lowerBound,
                      "标记顺序乱了")
    }

    /// delta 必须抽样：20 条/秒不抽样的话 256KB 两分钟写满，
    /// 真正的"帧没到"反而被冲掉。
    func testDeltaIsSampled() {
        for _ in 0..<24 { FrameLog.markDelta("item/agentMessage/delta", "x") }
        XCTAssertEqual(marks(), 1, "24 条 delta 应该只记第 1 条")
        FrameLog.markDelta("item/agentMessage/delta", "x")   // 第 25 条
        XCTAssertEqual(marks(), 2, "第 25 条应该记一条")
    }

    /// 不同 item 各算各的，不能串。
    func testDeltaSamplingIsPerItem() {
        FrameLog.markDelta("item/agentMessage/delta", "a")
        FrameLog.markDelta("item/agentMessage/delta", "b")
        XCTAssertEqual(marks(), 2, "两个 item 的第一条都要记")
    }

    private func marks() -> Int {
        FrameLog.read().components(separatedBy: " FRAME ").count - 1
    }
}

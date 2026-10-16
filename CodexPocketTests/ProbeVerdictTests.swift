import XCTest
@testable import CodexPocket

/// 探活判定。
///
/// 真机诊断数据（`lastDrop` 统计）：`probe-timeout` 占了断线的 42%，
/// 是最主要的一类。两个原因：
///   1. `lastPong` 跨队列裸读写（delegate 队列写、主队列读）是数据竞争，
///      读到的可能是旧值 → 活链路被判成死链。
///   2. 只要**一次**探活打空就拆链路。网络路径刚变、上行挤一下都会打空，
///      而链路其实好好的。
final class ProbeVerdictTests: XCTestCase {

    /// 收到东西 = 活着。
    func testGotSomethingIsAlive() {
        XCTAssertEqual(WebSocketTransport.probeVerdict(gotSomething: true, fails: 0), .alive)
        XCTAssertEqual(WebSocketTransport.probeVerdict(gotSomething: true, fails: 5), .alive)
    }

    /// **第一次打空不能拆链路** —— 这就是"动不动就断"的主因。
    func testFirstMissRetriesInsteadOfReconnecting() {
        XCTAssertEqual(WebSocketTransport.probeVerdict(gotSomething: false, fails: 1), .retry,
                       "一次探活打空就把链路拆了")
    }

    /// 连续打空才判定死链。
    func testSecondMissReconnects() {
        XCTAssertEqual(WebSocketTransport.probeVerdict(gotSomething: false, fails: 2), .reconnect)
        XCTAssertEqual(WebSocketTransport.probeVerdict(gotSomething: false, fails: 3), .reconnect)
    }

    /// 阈值要可配（测试和以后调参都靠它）。
    func testThresholdIsConfigurable() {
        XCTAssertEqual(WebSocketTransport.probeVerdict(gotSomething: false, fails: 1, maxFails: 1),
                       .reconnect)
        XCTAssertEqual(WebSocketTransport.probeVerdict(gotSomething: false, fails: 2, maxFails: 3),
                       .retry)
    }
}

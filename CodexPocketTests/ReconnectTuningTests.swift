import XCTest
@testable import CodexPocket

/// 断线判定的阈值。
///
/// 用户报的"WebSocket 十几秒断一次"，一部分是**探活误判**：
/// 原来的探活超时是 2.5 秒、心跳阈值 22 秒。手机在蜂窝上（或者 app-server
/// 正在推大消息）时一个来回很容易超 2.5 秒，链路明明活着却被自己拆掉重连。
/// 这两个数字调宽之后要锁住，别再被改回去 —— 直接读源码里的默认值。
final class ReconnectTuningTests: XCTestCase {

    private func rpcSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // CodexPocketTests
            .deletingLastPathComponent()      // 仓库根
            .appendingPathComponent("CodexPocket/Infrastructure/Transport/WebSocketTransport.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 探活超时必须够宽，否则蜂窝上一个来回就被误判成死链。
    func testProbeTimeoutIsWide() throws {
        let s = try rpcSource()
        guard let r = s.range(of: "func probe(timeout: TimeInterval = ") else {
            return XCTFail("找不到 probe 的默认超时")
        }
        let tail = s[r.upperBound...].prefix(4)
        let v = Double(tail.prefix { $0.isNumber || $0 == "." }) ?? 0
        XCTAssertGreaterThanOrEqual(v, 5, "探活超时 \(v)s 太短，会把活链路判成死链")
    }

    /// 心跳阈值要能容忍连丢几次 15s 的桥接心跳。
    func testHeartbeatThresholdIsWide() throws {
        let s = try rpcSource()
        guard let r = s.range(of: "timeIntervalSince(self.lastPong) > ") else {
            return XCTFail("找不到心跳阈值")
        }
        let tail = s[r.upperBound...].prefix(4)
        let v = Double(tail.prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThanOrEqual(v, 40, "心跳阈值 \(v)s 太短，tick 迟到一次就会重连")
    }

    /// 诊断字段要存在，否则线上分不清断线是对端掐的还是自己拆的。
    @MainActor
    func testDropDiagnostics() {
        let rpc = WebSocketTransport()
        XCTAssertEqual(rpc.drops, 0)
        XCTAssertEqual(rpc.connects, 0)
        XCTAssertEqual(rpc.lastDrop, "")
        rpc.probe()      // 没连接时直接返回，不能崩
    }
}

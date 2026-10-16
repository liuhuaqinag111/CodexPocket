import XCTest
@testable import CodexPocket

/// 认不出的条目**不能静默丢弃**。
///
/// `Protocol_.item` 的 default 分支以前是：有文本 → 当助手回复；
/// 没文本 → 返回 nil。而服务端发的 plan / todo / imageView / webSearch /
/// 多 agent 协作等十几种条目**大多没有 text 字段** —— 全部凭空消失，
/// 用户看到的是一段内容莫名其妙断掉。
final class UnknownItemTests: XCTestCase {

    private func d(_ s: String) -> JSONDict {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? JSONDict ?? [:]
    }

    /// 完全没见过的类型也要出一条。
    func testUnknownTypeIsNotDropped() {
        let it = Protocol_.item(from: d(#"{"id":"x1","type":"brandNewThing","foo":"bar"}"#))
        XCTAssertNotNil(it, "认不出的条目被丢掉了")
        guard case .note(_, let label, let detail)? = it else {
            return XCTFail("应该渲染成中性条目，实际 \(String(describing: it))")
        }
        XCTAssertEqual(label, "brandNewThing")
        XCTAssertEqual(detail, "foo=bar", "只列键名看不出这是什么事件，要带上值")
    }

    /// 已知但以前被丢的几种。
    func testKnownButPreviouslyDroppedTypes() {
        for (type, expect) in [("imageView", "查看图片"),
                               ("webSearch", "联网搜索"),
                               ("imageGeneration", "生成图片"),
                               ("collabAgentToolCall", "多 Agent 协作")] {
            let it = Protocol_.item(from: d("{\"id\":\"a\",\"type\":\"\(type)\"}"))
            guard case .note(_, let label, _)? = it else {
                return XCTFail("\(type) 被丢掉了")
            }
            XCTAssertEqual(label, expect)
        }
    }

    /// `sleep` 是纯噪音，要丢掉（不能什么都留）。
    func testSleepIsDropped() {
        XCTAssertNil(Protocol_.item(from: d(#"{"id":"s1","type":"sleep","durationMs":1000}"#)))
    }

    /// 计划要解析出来。
    func testPlanSteps() {
        let it = Protocol_.item(from: d("""
        {"id":"p1","type":"plan","steps":[
          {"text":"读代码","status":"completed"},
          {"text":"改代码","status":"inProgress"},
          {"text":"跑测试","status":"pending"}]}
        """))
        guard case .plan(_, let steps)? = it else { return XCTFail("计划没解析出来") }
        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].isDone)
        XCTAssertTrue(steps[1].isActive)
        XCTAssertFalse(steps[2].isDone)
    }

    /// 字段名换过（steps / items / todos），都要认。
    func testPlanFieldAliases() {
        for key in ["steps", "items", "todos"] {
            let it = Protocol_.item(from: d("{\"id\":\"p\",\"type\":\"plan\",\"\(key)\":[{\"text\":\"x\"}]}"))
            guard case .plan(_, let steps)? = it else {
                return XCTFail("\(key) 没认出来")
            }
            XCTAssertEqual(steps.count, 1)
        }
    }

    /// 有文本的未知类型仍然当助手回复（保持原行为）。
    func testTextStillBecomesAgent() {
        let it = Protocol_.item(from: d(#"{"id":"t1","type":"whatever","text":"正文"}"#))
        guard case .agent(_, let t)? = it else { return XCTFail("有文本的没当助手回复") }
        XCTAssertEqual(t, "正文")
    }
}

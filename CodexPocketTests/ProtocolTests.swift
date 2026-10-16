import XCTest

/// 协议解析的单元测试。
///
/// 这些 JSON 都是**从真实 app-server 抓下来的**（`thread/list`、
/// `thread/turns/list` 的原始回包），不是手编的。踩过的坑都在这里钉住：
///   1. 用户消息在 `turn.items` 里，不在 `turn.input` —— 按 input 解析会全丢。
///   2. `project.roots` 是 `[{"path": ...}]`，不是字符串数组。
@testable import CodexPocket

final class ProtocolTests: XCTestCase {

    func testWhitespaceOnlyHistoryAgentIsIgnored() {
        let rows = Protocol_.items(fromTurn: ["id": "t", "items": [
            ["id": "blank", "type": "agentMessage", "text": " \n\u{2028}\t"],
            ["id": "real", "type": "agentMessage", "text": "有正文"]
        ]])
        XCTAssertFalse(rows.contains { $0.id == "blank" },
                       "历史空白 agent 不应渲染成只有 Codex 标题的空行")
        XCTAssertTrue(rows.contains(.agent(id: "real", text: "有正文")))
    }

    func testAgentMarkdownImageKeepsOriginalTextAndAddsPreview() {
        let text = "图片如下：\n![预览](</tmp/my image.png>)\n说明保留"
        let rows = Protocol_.items(fromTurn: ["id": "t", "items": [["id": "a", "type": "agentMessage", "text": text]]])
        guard case .agent(_, let original) = rows[0] else { return XCTFail("正文丢失") }
        XCTAssertEqual(original, text)
        XCTAssertTrue(Markdown.blocks(original).contains { block in
            if case .image(_, let source) = block { return source == "/tmp/my image.png" }
            return false
        }, "原始正文应在实际Markdown渲染层生成图片")
        XCTAssertFalse(rows.contains { if case .image = $0 { return true }; return false },
                       "正文内图片不应在历史列表再插一份")
    }

    func testMCPImagesRenderAlongsideTextAndToolMetadata() {
        let turn: JSONDict = ["id": "turn", "items": [["id": "tool", "type": "mcpToolCall",
            "server": "image", "tool": "render", "status": "completed", "arguments": [:],
            "result": ["content": [["type": "text", "text": "完成"],
                ["type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="]]]]]]
        let rows = Protocol_.items(fromTurn: turn)
        guard case .tool(_, _, _, _, _, let result, _) = rows[0] else { return XCTFail("工具行丢失") }
        XCTAssertTrue(result.contains("完成"))
        XCTAssertFalse(result.contains("iVBOR"))
        guard case .image(_, let source) = rows[1] else { return XCTFail("MCP图片未显示") }
        XCTAssertEqual(source, "data:image/png;base64,iVBORw0KGgo=")
    }

    func testSchemaImageViewAndImageGenerationUseActualSources() {
        guard case .image("view", "/tmp/photo.png") = Protocol_.item(from: ["id": "view", "type": "imageView", "path": "/tmp/photo.png"]) else { return XCTFail("imageView 未显示") }
        guard case .image("gen", "/tmp/generated.png") = Protocol_.item(from: ["id": "gen", "type": "imageGeneration", "status": "completed", "result": "", "savedPath": "/tmp/generated.png"]) else { return XCTFail("生成图未读取 savedPath") }
        let data = "data:image/png;base64,iVBORw0KGgo="
        guard case .image(_, let source) = Protocol_.item(from: ["id": "gen", "type": "imageGeneration", "status": "completed", "result": data]) else { return XCTFail("自描述图片结果丢失") }
        XCTAssertEqual(source, data)
        guard case .image(_, let base64Source) = Protocol_.item(from: ["id": "gen", "type": "imageGeneration", "status": "completed", "result": "iVBORw0KGgo="]) else { return XCTFail("PNG签名结果丢失") }
        XCTAssertEqual(base64Source, "data:image/png;base64,iVBORw0KGgo=")
        guard case .note = Protocol_.item(from: ["id": "failed", "type": "imageGeneration", "status": "failed", "result": "usage limit exceeded"]) else { return XCTFail("状态文字被误当图片") }
    }

    private func json(_ s: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(s.utf8))
    }

    /// 真实回包（截取）：一个含 userMessage + agentMessage 的回合。
    func testTurnItemsKeepUserMessage() {
        let raw = """
        {"data":[{"id":"t1","status":"completed","startedAt":1790254549,
        "completedAt":1790254600,"durationMs":51000,"items":[
          {"id":"i1","type":"userMessage","clientId":"c1",
           "content":[{"type":"text","text":"你搞吧"}]},
          {"id":"i2","type":"agentMessage","text":"好","phase":"final"},
          {"id":"i3","type":"reasoning","summary":["先看用户要什么"],"content":[]}
        ]}]}
        """
        let items = Protocol_.items(fromTurns: json(raw))
        XCTAssertEqual(items.count, 4, "3 个 item + 1 条回合分隔线")
        guard case .user(_, let text, _) = items[0] else {
            return XCTFail("第一条应该是用户消息，实际 \(items[0])")
        }
        XCTAssertEqual(text, "你搞吧")
        guard case .agent(_, let reply) = items[1] else {
            return XCTFail("第二条应该是助手回复")
        }
        XCTAssertEqual(reply, "好")
        // 思考过程在 summary 里，只读 content 会丢（用户："为什么不显示思考过程"）。
        guard case .reasoning(_, let think) = items[2] else {
            return XCTFail("第三条应该是思考过程，实际 \(items[2])")
        }
        XCTAssertEqual(think, "先看用户要什么")
        guard case .turnBreak(_, _, let d) = items[3] else {
            return XCTFail("最后一条应该是回合分隔线")
        }
        XCTAssertEqual(d ?? 0, 51, accuracy: 0.01, "用时要从 durationMs 取")
    }

    /// 项目 roots 的真实形状：`[{"path": "..."}]`。
    func testProjectRootsAreObjects() {
        let raw = """
        {"id":"p1","name":"知识库","roots":[{"path":"/Users/test/Documents/知识库"}]}
        """
        let p = Project(json: json(raw) as! JSONDict)
        XCTAssertEqual(p?.roots, ["/Users/test/Documents/知识库"])
        XCTAssertEqual(p?.name, "知识库")
    }

    /// 归属判定：cwd 等于根目录、或在其子目录下都算，前缀相似的不算。
    func testProjectOwnership() {
        let p = Project(json: json("""
        {"id":"p1","name":"竞彩","roots":[{"path":"/Users/test/Documents/竞彩"}]}
        """) as! JSONDict)!
        XCTAssertTrue(p.owns(thread(cwd: "/Users/test/Documents/竞彩")))
        XCTAssertTrue(p.owns(thread(cwd: "/Users/test/Documents/竞彩/app")))
        XCTAssertFalse(p.owns(thread(cwd: "/Users/test/Documents/竞彩2")))
        XCTAssertFalse(p.owns(thread(cwd: "/")))
    }

    /// `thread/turns/list` 默认 desc（最新在前），解析出来必须是时间正序。
    ///
    /// 回归：回前台重新拉取时用了服务端的默认顺序，最新一条跑到列表最上面
    /// （用户："我发完消息切后台，切回来新消息怎么变成最上面的一条了"）。
    func testDescTurnsArePutBackInOrder() {
        let raw = """
        {"data":[
          {"id":"t2","status":"completed","startedAt":1790254600,
           "items":[{"type":"agentMessage","id":"a2","text":"第二句"}]},
          {"id":"t1","status":"completed","startedAt":1790254500,
           "items":[{"type":"agentMessage","id":"a1","text":"第一句"}]}
        ]}
        """
        let items = Protocol_.items(fromTurns: json(raw))
        // 每个回合末尾会跟一条空文本的 turnBreak，比较时滤掉。
        XCTAssertEqual(items.map { $0.text }.filter { !$0.isEmpty }, ["第一句", "第二句"])
    }

    /// 已经是正序的不要被反转。
    func testAscTurnsAreLeftAlone() {
        let raw = """
        {"data":[
          {"id":"t1","status":"completed","startedAt":1790254500,
           "items":[{"type":"agentMessage","id":"a1","text":"第一句"}]},
          {"id":"t2","status":"completed","startedAt":1790254600,
           "items":[{"type":"agentMessage","id":"a2","text":"第二句"}]}
        ]}
        """
        let items = Protocol_.items(fromTurns: json(raw))
        XCTAssertEqual(items.map { $0.text }.filter { !$0.isEmpty }, ["第一句", "第二句"])
    }

    func testSameNamedThreadsWithDifferentIDsAreKept() {
        let rows = [
            Thread(json: ["id": "a", "name": "同名", "cwd": "/repo", "updatedAt": 2])!,
            Thread(json: ["id": "b", "name": "同名", "cwd": "/repo", "updatedAt": 1])!
        ]
        XCTAssertEqual(Protocol_.dedupe(rows).map(\.id), ["a", "b"])
    }

    private func thread(cwd: String) -> CodexPocket.Thread {
        Thread(json: ["id": "t", "cwd": cwd])!
    }
}

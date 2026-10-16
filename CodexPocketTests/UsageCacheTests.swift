import XCTest
@testable import CodexPocket

/// 用户截图：打开用量页显示"这个会话还没跑过，暂时没有用量"。
///
/// 根因（实测）：服务端**没有**查历史用量的方法 ——
///   `thread/read` 里没有任何带 token 的字段，
///   `thread/turns/list` 的 turn 只有 id/status/startedAt/completedAt/durationMs，
///   `thread/resume` 既不回 usage 也不补发事件。
/// 用量只在跑回合时推一次 `thread/tokenUsage/updated`。
/// 所以本地必须把它记下来，否则打开旧会话永远是空的。
final class UsageCacheTests: XCTestCase {

    private let id = "test-usage-" + UUID().uuidString

    override func tearDown() {
        UsageCache.drop(id)
        super.tearDown()
    }

    func testRoundTrip() {
        let u = TokenUsage(json: ["tokenUsage": ["totalTokens": 12345,
                                                "inputTokens": 12000,
                                                "outputTokens": 345,
                                                "cachedInputTokens": 9000,
                                                "reasoningOutputTokens": 100],
                                  "modelContextWindow": 500000])!
        UsageCache.save(id, u)
        let back = UsageCache.load(id)
        XCTAssertNotNil(back, "存进去的用量读不回来")
        XCTAssertEqual(back?.usage.total, 12345)
        XCTAssertEqual(back?.usage.input, 12000)
        XCTAssertEqual(back?.usage.output, 345)
        XCTAssertEqual(back?.usage.cached, 9000)
        XCTAssertEqual(back?.usage.contextWindow, 500000)
        // 百分比要能算出来（窗口未知时会显示假的 0%，这里必须是真的）。
        XCTAssertEqual(back?.usage.percent, 2)
    }

    func testUnknownIdReturnsNil() {
        XCTAssertNil(UsageCache.load("从来没有过的会话 id"))
    }

    /// `open()` 必须真的把缓存读进 `chat.usage`。
    /// 只测 UsageCache 自己不够 —— 接线断了照样是空白页。
    @MainActor
    func testOpenRestoresUsage() {
        let u = TokenUsage(json: ["tokenUsage": ["totalTokens": 7777],
                                  "modelContextWindow": 100000])!
        UsageCache.save(id, u)
        let chat = ConversationModel(repository: ConversationRepository(transport: WebSocketTransport(), cache: AppCoordinator.makeCache(namespace: "unit-tests")), settings: PreferencesModel(),
                             list: ThreadListModel(repository: ThreadRepository(transport: WebSocketTransport()), settings: PreferencesModel()))
        XCTAssertNil(chat.usage, "一开始不该有值")
        chat.restoreUsage(id)
        XCTAssertEqual(chat.usage?.total, 7777, "打开会话时没把上次的用量读回来")
    }

    func testDrop() {
        let u = TokenUsage(json: ["totalTokens": 1])!
        UsageCache.save(id, u)
        XCTAssertNotNil(UsageCache.load(id))
        UsageCache.drop(id)
        XCTAssertNil(UsageCache.load(id))
    }
}

/// 服务端推的**真实**包结构（2026-10-02 抓包）：
///   {"threadId":"…","turnId":"…","tokenUsage":{
///      "total":{…},"last":{…},"modelContextWindow":475000}}
///
/// 以前的解析读 `tokenUsage.totalTokens` —— 嵌套一层，**每一包都失败**，
/// 所以用量页永远显示"这个会话还没跑过"。这是那个空页面的真根因，
/// 不是"服务端没有历史用量"（那个只是没法查旧会话，不是空页的原因）。
final class TokenUsageShapeTests: XCTestCase {

    private let real: JSONDict = [
        "threadId": "00000000-0000-4000-8000-000000000003",
        "turnId": "00000000-0000-4000-8000-000000000004",
        "tokenUsage": [
            "total": ["totalTokens": 17834340, "inputTokens": 17677458,
                      "cachedInputTokens": 17294720, "cacheWriteInputTokens": 0,
                      "outputTokens": 156882, "reasoningOutputTokens": 0],
            "last": ["totalTokens": 142862, "inputTokens": 142376,
                     "cachedInputTokens": 142208, "cacheWriteInputTokens": 0,
                     "outputTokens": 486, "reasoningOutputTokens": 0],
            "modelContextWindow": 475000,
        ],
    ]

    /// 真实包必须解析成功，而且取的是 `last`（这一轮的上下文占用），
    /// 不是 `total`（整个会话累计 17.8M，比窗口大得多，百分比会永远 100%）。
    func testRealServerShapeParses() {
        let u = TokenUsage(json: real)
        XCTAssertNotNil(u, "真实包解析不出来 —— 用量页会一直是空的")
        XCTAssertEqual(u?.total, 142862)
        XCTAssertEqual(u?.input, 142376)
        XCTAssertEqual(u?.output, 486)
        XCTAssertEqual(u?.cached, 142208)
    }

    /// 窗口在外层，取完 last 之后还得能读到。
    func testContextWindowReadFromOuterObject() {
        let u = TokenUsage(json: real)
        XCTAssertEqual(u?.contextWindow, 475000)
        XCTAssertEqual(u?.percent, 30)
    }
}

/// 桥接补拉那条路的解析（`GET /usage` 回的 `{usage:{total,last,…}}`）。
///
/// 服务端查不到历史用量，只能靠桥接记。这里锁住"桥接存下来的形态
/// 能还原成 TokenUsage"，否则补拉回来了也显示不出来。
final class UsageFetchShapeTests: XCTestCase {

    func testBridgeStoredShapeParses() {
        // 桥接存的就是事件里的 `tokenUsage` 原样。
        let stored: JSONDict = [
            "total": ["totalTokens": 900, "inputTokens": 800, "outputTokens": 100],
            "last": ["totalTokens": 300, "inputTokens": 280, "outputTokens": 20,
                     "cachedInputTokens": 256],
            "modelContextWindow": 100000,
        ]
        let u = TokenUsage(json: ["tokenUsage": stored])
        XCTAssertNotNil(u, "桥接补拉回来的用量解析不出来")
        XCTAssertEqual(u?.total, 300, "应该取 last（这一轮），不是 total（整个会话）")
        XCTAssertEqual(u?.cached, 256)
        XCTAssertEqual(u?.contextWindow, 100000)
    }
}

final class RealBridgeUsageFetchTests: XCTestCase {
    func testParseRealBridgeUsageResponse() {
        let jsonStr = """
        {"usage":{"total":{"totalTokens":17834340,"inputTokens":17677458,"cachedInputTokens":17294720,"cacheWriteInputTokens":0,"outputTokens":156882,"reasoningOutputTokens":0},"last":{"totalTokens":142862,"inputTokens":142376,"cachedInputTokens":142208,"cacheWriteInputTokens":0,"outputTokens":486,"reasoningOutputTokens":0},"modelContextWindow":475000},"at":1790942830413}
        """
        let data = jsonStr.data(using: .utf8)!
        let o = (try! JSONSerialization.jsonObject(with: data)) as! JSONDict
        let u = o.dict("usage")!
        let tokenUsage = TokenUsage(json: ["tokenUsage": u])
        XCTAssertNotNil(tokenUsage, "必须解析出 TokenUsage")
        XCTAssertEqual(tokenUsage?.total, 142862)
        XCTAssertEqual(tokenUsage?.percent, 30)
    }
}

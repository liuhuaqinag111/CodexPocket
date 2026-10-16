import XCTest
@testable import CodexPocket

/// 源码检查读取当前 checkout，不读取开发者电脑上的已部署服务。
enum TestSource {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
    static func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }
    static func optionalBuildScript(_ relative: String) throws -> String {
        let source = path(relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source),
                          "此 checkout 未包含旧的本地打包脚本：\(relative)")
        return try String(contentsOfFile: source, encoding: .utf8)
    }
}

/// 「已在另一个应用中打开 / 请先在那边关闭会话」。
///
/// `thread/resume` 会拿下会话的**写者锁**（`~/.codex/thread-writer-locks/<id>.lock`，
/// 进程级 flock），而协议里没有"卸载会话"的方法：`thread/unsubscribe` 实测
/// 只解订阅、锁不放，锁只在 app-server 进程退出时由内核释放。
///
/// 以前手机端**一打开会话就 resume**，于是点开过的每个会话都被手机锁住，
/// 桌面端再也打不开。实测手机那个 app-server 连跑 5 小时 18 分一直占着锁。
final class WriterLockTests: XCTestCase {

    /// 打开会话**不许** resume —— 只看内容不需要锁。
    @MainActor
    func testOpenDoesNotResume() throws {
        let src = try source("CodexPocket/Features/Chat/ConversationHistory.swift")
        let open = try XCTUnwrap(body(src, "func open(id: String"),
                                  "找不到 open(id:)")
        XCTAssertFalse(open.contains(".resume("),
                       "open 里还在 resume —— 光看会话就把桌面端的写者锁抢了")
    }

    /// 拿锁必须推迟到用户真的按发送。
    @MainActor
    func testResumeHappensOnlyOnSend() async {
        let transport = WriterSendTransport()
        let store = AppCoordinator(transport: transport)
        store.list.currentID = "t1"
        store.chat.send("hello", localID: "local-lock")
        await fulfillment(of: [transport.resumed], timeout: 1)
        XCTAssertFalse(transport.calls.contains { $0.0 == "turn/start" })
        XCTAssertEqual(transport.calls.first { $0.0 == "thread/resume" }?.1.bool("excludeTurns"), true)
        transport.resumeReply?(.success([:] as JSONDict))
        await fulfillment(of: [transport.started], timeout: 1)
        XCTAssertEqual(transport.calls.first { $0.0 == "turn/start" }?.1.str("clientUserMessageId"), "local-lock")
        store.chat.close()
    }

    /// **切后台不许自动放锁。**
    ///
    /// 放锁 = 重启 app-server，代价是排队消息全丢、十几秒连不上。
    /// 2026-10-07：以前这里无条件调 `/release`，App 切后台时一秒触发三次，
    /// 用户下午发的几条消息正好打进那些 ECONNREFUSED 窗口 —— 永久丢失。
    /// 现在改成设置里的显式按钮。
    @MainActor
    func testBackgroundDoesNotAutoRelease() throws {
        let src = try source("CodexPocket/App/AppCoordinator.swift")
        let bg = try XCTUnwrap(body(src, "func enterBackground()"), "找不到 enterBackground")
        XCTAssertFalse(bg.contains("releaseWriterLocks()"),
                       "切后台又自动放锁了 —— 会再次把用户正在发的消息打进断线窗口")
    }

    /// 放锁必须留给用户显式操作。
    @MainActor
    func testReleaseIsExplicitInSettings() throws {
        let src = try source("CodexPocket/Features/Settings/SettingsView.swift")
        XCTAssertTrue(src.contains("releaseWriterLocks()"),
                      "设置里没有放锁按钮 —— 桌面端被占住时用户没办法")
    }

    /// 桥接的 /release 要有三道闸。
    ///
    /// 只挡 activeTurns 不够：用户刚打开 App、消息正在飞的时候也会被放锁。
    func testBridgeReleaseHasGuards() throws {
        let src = try String(contentsOfFile: TestSource.path("bridge/bridge.mjs"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("RELEASE_QUIET_MS"),
                      "/release 不看最近有没有活动 —— 人正在用也会被重启")
        XCTAssertTrue(src.contains("RELEASE_COOLDOWN_MS"),
                      "/release 没有冷却 —— 会被连着触发（实测一秒三次）")
        XCTAssertTrue(src.contains("lastClientActivity"),
                      "/release 没记录客户端活动时间")
    }

    /// 桥接的 /release 要有安全闸：有回合在跑就不放。
    func testReleaseGuardExists() throws {
        let src = try String(contentsOfFile: TestSource.path("bridge/bridge.mjs"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("'/release'"), "桥接没有 /release")
        XCTAssertTrue(src.contains("activeTurns.size"),
                      "/release 不看 activeTurns —— 会把用户正在跑的回合杀掉")
    }

    /// 桥接的空闲释放**不能**拿 clients.size 当判据。
    ///
    /// App 为了"一切后台就断联"故意保持长连接（保活），clients.size 永远是 1，
    /// 拿它当判据等于释放逻辑永远不触发 —— 这就是锁被占 5 小时的原因。
    func testIdleReleaseDoesNotGateOnClients() throws {
        let src = try String(contentsOfFile: TestSource.path("bridge/bridge.mjs"),
                             encoding: .utf8)
        let marker = "function armIdleRestart()"
        guard let r = src.range(of: marker) else { return XCTFail("找不到 armIdleRestart") }
        let tail = String(src[r.lowerBound...].prefix(1200))
        XCTAssertFalse(tail.contains("if (clients.size || activeTurns.size) return"),
                       "空闲释放又被 clients.size 卡住了 —— 保活开着就永远不放锁")
    }

    // MARK: - 源码切片

    private func source(_ rel: String) throws -> String {
        return try String(contentsOfFile: TestSource.path(rel), encoding: .utf8)
    }

    /// 从签名处截到下一个同缩进的 `func `（够这几条测试用）。
    ///
    /// **注释要剥掉**：这几段代码的注释里本来就写着 `thread/resume`
    /// （解释为什么不能在这儿调它），不剥的话断言永远为真 ——
    /// 第一次跑就是这么假红的。
    private func body(_ src: String, _ sig: String) -> String? {
        guard let r = src.range(of: sig) else { return nil }
        let tail = src[r.lowerBound...]
        var out: [String] = []
        for (i, line) in tail.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0, line.hasPrefix("    func ") || line.hasPrefix("    private func ")
                || line.hasPrefix("    @MainActor") { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") { continue }
            out.append(String(line))
        }
        return out.joined(separator: "\n")
    }
}

private final class WriterSendTransport: RPCTransport {
    var calls: [(String, JSONDict)] = []
    var resumeReply: RepositoryResult?
    let resumed = XCTestExpectation(description: "resume before start")
    let started = XCTestExpectation(description: "start after resume")
    func rpc(_ method: String, _ params: JSONDict, done: RepositoryResult?) -> Int {
        calls.append((method, params))
        if method == "thread/resume" { resumeReply = done; resumed.fulfill() }
        else {
            if method == "turn/start" { started.fulfill() }
            done?(.success(["data": []] as JSONDict))
        }
        return calls.count
    }
}

import XCTest
@testable import CodexPocket

/// 缓存不能"写一次就永远不刷新"。
///
/// 用户报的：「我装上了 但是聊天记录是以前的 不是最新的」。
///
/// 实测证据（对比缓存文件和服务端 `thread/turns/list`）：
///   你给我找一下这个免服务器
///     服务端最新 6 个回合: 577d85,3a6648,32066d,9a88c3,daa072,ecf101
///     缓存里最新的:        daa072,ecf101,...        ← 差 4 个回合
///   能不能写一个远程控制电脑
///     缓存里 40 条，最新那条 67e3d0 早就不在服务端最新 6 个里了
///
/// 根因：`prefetch` 用 `!cache.has(id)` 筛，已经有缓存的会话
/// **永远不会被重拉** —— 缓存写一次就冻结在那里。
@MainActor
final class CacheFreshTests: XCTestCase {

    func testCacheKeysDoNotAliasDifferentThreads() {
        XCTAssertNotEqual(SnapshotCache.safe("a/b"), SnapshotCache.safe("a_b"))
        XCTAssertNotEqual(SnapshotCache.safe("a/b"), SnapshotCache.safe("a%2Fb"))
        XCTAssertFalse(SnapshotCache.safe("../a").contains("/"))
        XCTAssertEqual(SnapshotCache.safe("thread-123_abc"), "thread-123_abc")
    }

    private let cache = AppCoordinator.makeCache(namespace: "cache-tests")

    private let id = "fresh-test-thread"

    override func tearDown() {
        cache.drop(id)
        super.tearDown()
    }

    /// 缓存写入时间要能反映真实修改（预取的判据靠它）。
    func testModifiedAtTracksWrites() throws {
        cache.save(id, Data("{}".utf8))
        let first = try XCTUnwrap(cache.modifiedAt(id))
        Thread.sleep(forTimeInterval: 1.2)
        cache.save(id, Data("{\"x\":1}".utf8))
        let second = try XCTUnwrap(cache.modifiedAt(id))
        XCTAssertGreaterThan(second.timeIntervalSince(first), 1.0,
                             "重写缓存后写入时间没更新 —— 预取会一直以为它新鲜")
    }

    /// **核心判据**：写过一次但已经过期的缓存，必须判成要重拉。
    ///
    /// 这就是用户报的那个 bug：`prefetch` 以前只看"有没有缓存"，
    /// 有就不拉了，于是缓存写一次就冻结 —— 电脑端再跑几个回合，
    /// 手机点进去看到的还是旧记录。
    func testOldCacheIsStaleEvenThoughItExists() throws {
        cache.save(id, Data("{}".utf8))
        XCTAssertTrue(cache.has(id), "前提：缓存文件在")

        XCTAssertTrue(cache.isStale(id, now: Date().addingTimeInterval(1800)),
                      "Expired snapshots must be refreshed")
    }

    /// 刚写的缓存不重拉（别把 app-server 打满）。
    func testFreshCacheIsNotStale() {
        cache.save(id, Data("{}".utf8))
        XCTAssertFalse(cache.isStale(id), "刚写的缓存不该重拉")
    }

    /// 没有缓存 → 要拉。
    func testMissingCacheIsStale() {
        cache.drop(id)
        XCTAssertTrue(cache.isStale(id))
    }

    /// 过期阈值要有意义。
    func testFreshnessWindowIsSane() {
        XCTAssertGreaterThanOrEqual(SnapshotCache.freshFor, 60, "刷新太频繁会把 app-server 打满")
        XCTAssertLessThanOrEqual(SnapshotCache.freshFor, 3600, "刷新太慢用户就会看到过期内容")
    }

}

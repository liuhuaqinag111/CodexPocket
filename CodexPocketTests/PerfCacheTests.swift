import XCTest
@testable import CodexPocket

/// 为「上下滑好卡」加的两处缓存，必须**在内容变化时失效**。
///
/// 缓存写错方向比不缓存更糟：不缓存只是慢，缓存不失效就是内容停在旧的
/// （这一轮已经因为"缓存写一次就冻结"被用户骂过一次）。
final class PerfCacheTests: XCTestCase {

    @MainActor
    func testMutationDoesNotReuseAnotherStoresGeneration() {
        let a = AppCoordinator().chat
        let b = AppCoordinator().chat
        a.items = [.agent(id: "a", text: "A")]
        XCTAssertNotEqual(a.gen, b.gen)
    }

    // MARK: Grouping 的排序缓存

    /// 内容变了（`items` 的 `didSet` 推进代数）→ 必须重新排序。
    @MainActor
    func testRowsCacheInvalidatesWhenItemsChange() {
        let store = AppCoordinator()
        store.chat.items = [.turnBreak(id: "tb-1", at: Date(), duration: 1),
                            .agent(id: "a1", text: "先有的正文")]
        let before = Grouping.rows(store.chat.items, liveTurnId: nil, gen: store.chat.gen)
            .map { $0.id }

        store.chat.items.insert(.reasoning(id: "r1", text: "后到的思考"), at: 0)
        let after = Grouping.rows(store.chat.items, liveTurnId: nil, gen: store.chat.gen)
            .map { $0.id }
        XCTAssertNotEqual(before, after, "内容变了还吃旧缓存 —— 界面会冻在旧内容上")
        XCTAssertTrue(after.contains { $0.contains("r1") || $0.hasPrefix("work-") },
                      "新加的思考没进渲染结果：\(after)")
    }

    /// 内容没变 → 必须命中缓存（否则等于没加）。
    /// 没传 `gen`（单元测试的常规用法）时**必须不缓存** —— 早先缓存键是
    /// 模块级全局量，测试之间互相串，10 条老测试直接变红。
    @MainActor
    func testRowsCacheHitsWhenNothingChanges() {
        let store = AppCoordinator()
        store.chat.items = [.user(id: "u1", text: "问", images: []),
                            .agent(id: "a1", text: "答")]
        let a = Grouping.rows(store.chat.items, liveTurnId: nil, gen: store.chat.gen).map { $0.id }
        let b = Grouping.rows(store.chat.items, liveTurnId: nil, gen: store.chat.gen).map { $0.id }
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, ["u1", "a1"])
    }

    /// 两个会话（两个 `ConversationModel`）的内容代数**不能撞**。
    ///
    /// `Grouping.rows` 的缓存是模块级单格，键就是 `gen`。实例各自从 0 自增的话，
    /// 第二个 store 的 `gen=1` 会命中第一个 store `gen=1` 留下的缓存 ——
    /// 拿别人的渲染结果当自己的。单元测试踩过这个坑（每个用例都 new 一个
    /// `AppCoordinator`，"新内容撞旧缓存"成了常态，10 条老测试变红）。
    @MainActor
    func testTwoStoresDoNotShareCache() {
        let a = AppCoordinator()
        let b = AppCoordinator()
        XCTAssertNotEqual(a.chat.gen, b.chat.gen,
                          "两个会话的内容代数撞了 —— 会拿到对方的渲染缓存")

        a.chat.items = [.agent(id: "a1", text: "甲的正文")]
        b.chat.items = [.agent(id: "b1", text: "乙的正文")]
        XCTAssertNotEqual(a.chat.gen, b.chat.gen)

        let ra = Grouping.rows(a.chat.items, liveTurnId: nil, gen: a.chat.gen).map { $0.id }
        let rb = Grouping.rows(b.chat.items, liveTurnId: nil, gen: b.chat.gen).map { $0.id }
        XCTAssertEqual(ra, ["a1"])
        XCTAssertEqual(rb, ["b1"], "乙拿到了甲的渲染结果 —— 内容串了")
    }

}

import XCTest
@testable import CodexPocket

/// 「把会话归到项目」。
///
/// 服务端**没有**可写的 thread→project 映射（实测三条路都不通）：
///   * `project/move` / `project/update` 回 `{}`，库里 project_id 始终 NULL；
///   * `thread/settings/update { cwd }` 只改 state_5.sqlite，而 thread/list
///     的 cwd 读的是 rollout 文件 —— 库里变了接口仍回旧值。
/// 所以归属记在本地，界面立刻生效。
final class MoveProjectTests: XCTestCase {

    private func project(_ id: String, _ name: String, _ root: String) -> Project {
        Project(json: ["id": id, "name": name, "roots": [["path": root]]])!
    }

    /// 归到项目后 `project(of:)` 要认它 —— 列表分组靠的就是这个。
    @MainActor
    func testMovePutsThreadUnderProject() {
        let store = AppCoordinator()
        store.list.clearFiled()
        store.list.inject(projects: [project("PA", "A", "/Users/test/Documents/竞彩")])
        let t = Thread(json: ["id": "T1", "name": "x", "cwd": "/tmp"])!
        store.list.inject(threads: [t])
        XCTAssertNil(store.list.project(of: t), "前置：不该已经在项目里")

        store.list.move(t, to: store.list.projects[0])
        XCTAssertEqual(store.list.project(of: t)?.id, "PA", "归到项目没生效")
    }

    /// 移出项目后回到「最近」。
    @MainActor
    func testUnfileRemovesFromProject() {
        let store = AppCoordinator()
        store.list.clearFiled()
        store.list.inject(projects: [project("PA", "A", "/Users/test/Documents/竞彩")])
        let t = Thread(json: ["id": "T2", "name": "x", "cwd": "/tmp"])!
        store.list.inject(threads: [t])

        store.list.move(t, to: store.list.projects[0])
        XCTAssertEqual(store.list.project(of: t)?.id, "PA")
        store.list.unfile(t)
        XCTAssertNil(store.list.project(of: t), "移出项目没生效")
    }

    /// 用户手动归的不能被 cwd 前缀抢回去。
    @MainActor
    func testManualFilingBeatsCwdPrefix() {
        let store = AppCoordinator()
        store.list.clearFiled()
        store.list.inject(projects: [
            project("PA", "A", "/Users/test/Documents/竞彩"),
            project("PB", "B", "/Users/test/Documents/知识库"),
        ])
        let t = Thread(json: ["id": "T3", "name": "x",
                              "cwd": "/Users/test/Documents/竞彩"])!
        store.list.inject(threads: [t])
        XCTAssertEqual(store.list.project(of: t)?.id, "PA", "前置：按 cwd 应算 A")

        store.list.move(t, to: store.list.projects[1])
        XCTAssertEqual(store.list.project(of: t)?.id, "PB",
                       "手动归到 B 被 cwd 前缀抢回 A 了")
    }
}

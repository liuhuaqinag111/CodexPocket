import XCTest
@testable import CodexPocket

/// 「一进会话看到的是旧聊天记录」。
///
/// 复现路径：缓存里只有最近 6 轮（`cacheTurns`），`reload` 一次拉 12 轮
/// （`firstPage`）—— 服务端多给 6 轮**更旧的**。`mergeTail` 以前把没见过的
/// 一律 append 到末尾，末尾是最新那一端，界面又钉在底部：
/// 用户点进会话，屏幕停在一条旧回合上。
final class MergeOrderTests: XCTestCase {

    /// 本地只有"最新两轮"，服务端给了"最新两轮 + 更早两轮"。
    @MainActor
    func testOlderServerTurnsGoBeforeLocalOnes() {
        let store = AppCoordinator()
        store.chat.items = [
            .turnBreak(id: "tb-3", at: Date(), duration: 1),
            .user(id: "u3", text: "第三问", images: []),
            .agent(id: "a3", text: "第三答"),
            .turnBreak(id: "tb-4", at: Date(), duration: 1),
            .user(id: "u4", text: "第四问", images: []),
            .agent(id: "a4", text: "第四答"),
        ]

        // 服务端 desc limit 4 → 解析层反转过，这里给的就是时间正序。
        store.chat.mergeTail([
            .turnBreak(id: "tb-1", at: Date(), duration: 1),
            .user(id: "u1", text: "第一问", images: []),
            .agent(id: "a1", text: "第一答"),
            .turnBreak(id: "tb-2", at: Date(), duration: 1),
            .user(id: "u2", text: "第二问", images: []),
            .agent(id: "a2", text: "第二答"),
            .turnBreak(id: "tb-3", at: Date(), duration: 1),
            .user(id: "u3", text: "第三问", images: []),
            .agent(id: "a3", text: "第三答"),
            .turnBreak(id: "tb-4", at: Date(), duration: 1),
            .user(id: "u4", text: "第四问", images: []),
            .agent(id: "a4", text: "第四答"),
        ])

        let ids = store.chat.items.map { $0.id }
        XCTAssertEqual(ids, ["tb-1", "u1", "a1", "tb-2", "u2", "a2",
                             "tb-3", "u3", "a3", "tb-4", "u4", "a4"],
                       "更旧的回合必须插到本地内容**前面**，不能追加到末尾")
    }
}

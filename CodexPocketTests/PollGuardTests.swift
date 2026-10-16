import XCTest
@testable import CodexPocket

/// 「发消息不理我」的回归：弱网下 `turn/start` 的回包丢了怎么办。
///
/// 现场（2026-10-09 20:51，手机 v69.4）：用户在新会话里发「？」，
/// 服务端**跑了也回了**（rollout 里有完整回复），手机上什么都没有。
/// 根因是 `pollRemote` 的一句判定把整条兜底路堵死了：
/// 回包丢了 → `serverTurnId` 是 nil → 判定"这不是我发的回合" → return，
/// 内容不合并、`busy` 不复位 → 之后每条消息都被当成"在跑"送进排队。
final class PollGuardTests: XCTestCase {

    func testNilServerTurnIdIsNotExcluded() {
        // 回包丢了：serverTurnId 是 nil。**必须放行**，否则轮询永不生效。
        XCTAssertTrue(ConversationModel.polledTurnIsMine(
            localTurn: true, serverTurnId: nil, turnId: "turn-abc"),
                      "回包丢了就把轮询整个挡掉 —— 这正是「不理我」的根因")
    }

    func testOtherTurnIsExcluded() {
        // 拿到了 id，服务端最新回合是**别人**的 → 不能拿它覆盖本地。
        XCTAssertFalse(ConversationModel.polledTurnIsMine(
            localTurn: true, serverTurnId: "turn-mine", turnId: "turn-other"))
    }

    func testSameTurnPasses() {
        XCTAssertTrue(ConversationModel.polledTurnIsMine(
            localTurn: true, serverTurnId: "turn-mine", turnId: "turn-mine"))
    }

    func testRemoteTurnIsAlwaysAllowed() {
        // 不是本地发起的回合：这条路本来就要处理（电脑端跑的内容）。
        XCTAssertTrue(ConversationModel.polledTurnIsMine(
            localTurn: false, serverTurnId: nil, turnId: "turn-x"))
        XCTAssertTrue(ConversationModel.polledTurnIsMine(
            localTurn: false, serverTurnId: "turn-mine", turnId: "turn-other"))
    }

    func testMissingTurnIdWithKnownServerTurnIsExcluded() {
        // 服务端连回合 id 都没给，而我们知道自己在等哪个 → 排除。
        XCTAssertFalse(ConversationModel.polledTurnIsMine(
            localTurn: true, serverTurnId: "turn-mine", turnId: nil))
    }
}

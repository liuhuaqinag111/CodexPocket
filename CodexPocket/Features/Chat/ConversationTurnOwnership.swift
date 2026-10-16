import Foundation

/// 回合归属：**按会话记**，不跟着"当前打开哪个会话"走。
///
/// 用户报的 bug：「一直在一个会话里插话能用，我一切出去插话就变成排队了」。
///
/// 根因是 `open()` 会调 `resetSession()`，而它把 `serverTurnId` 和
/// `localTurn` 一起清成 nil / false。这两样是**会话**的属性，不是
/// "看没看着"的属性：
///
///   1. `serverTurnId` 没了 → `ComposerModel.action` 只能给「排队」。
///      `turn/steer` 的 `expectedTurnId` 是**必填**（服务端实测报
///      "missing field `expectedTurnId`"），没有 id 就插不了话。
///   2. `localTurn` 没了 → 轮询看到活动回合时 `if !localTurn` 成立，
///      把**手机自己发起的**回合误判成"电脑端占着"，`desktopLocked`
///      被永久置上（只有 `open()` / 发送成功才清），之后一直排队。
///
/// 所以归属按 threadId 存，会话切换只换"当前看哪个"，不动归属。
extension ConversationModel {
    /// 离屏丢过事件时，full 历史可能已经进入下一轮，不能再用旧回合挡住恢复。
    func reconcileRecoveredTurn(_ turn: JSONDict, threadID: String) {
        guard !streamIsContinuous, !configurationPreparing, sendingID == nil,
              list.currentID == threadID, let previous = serverTurnId,
              let incoming = turn.str("id"), !incoming.isEmpty, incoming != previous,
              turn["status"] != nil else { return }
        forgetTurn(threadID)
        lastTurnId = incoming
        busy = Self.isActive(turn)
        turnStarted = busy ? Date() : nil
        if busy {
            activeTurnIds[threadID] = incoming
            if ownsTurn(clientID: Self.turnClientId(turn)) { ownedTurnThreads.insert(threadID) }
            desktopLocked = !localTurn
        }
    }

    func forgetTurn(_ threadID: String) {
        activeTurnIds[threadID] = nil
        ownedTurnThreads.remove(threadID)
    }

    func forgetAllTurns() {
        suspendedTranscripts.removeAllObjects()
        invalidateStreamContinuity()
        cancelledSubmissionIDs.removeAll()
        activeTurnIds.removeAll()
        ownedTurnThreads.removeAll()
        desktopLockedThreads.removeAll()
    }

    /// 放锁成功（或换了连接）：所有会话的"被电脑端占着"都不再成立。
    func clearAllWriterLocks() {
        guard !desktopLockedThreads.isEmpty else { return }
        desktopLockedThreads.removeAll()
        objectWillChange.send()
    }

    /// 这条回合的用户消息是不是**我们本机**提交的。
    ///
    /// 靠 `clientUserMessageId`（`turn/start` / `turn/steer` /
    /// `thread/queue/add` 都带，服务端原样回显）判，不靠 `localTurn` 猜
    /// —— 猜错就会把手机自己的回合当成电脑端的，然后永远排队。
    func ownsTurn(clientID: String?) -> Bool {
        guard let clientID, !clientID.isEmpty else { return false }
        if acceptedSubmissionIDs.contains(clientID) { return true }
        if activeSubmissionIDs.contains(clientID) { return true }
        if sendingID == clientID { return true }
        if pendingSend?.id == clientID { return true }
        return false
    }
}

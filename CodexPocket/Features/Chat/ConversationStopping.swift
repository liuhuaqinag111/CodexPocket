import Foundation



extension ConversationModel {
    /// 这个回合**我们停得掉吗**。
    ///
    /// `turn/interrupt` 只认「发起该回合的那条连接」手里的 turn id
    /// （实测：同连接发起的回合，interrupt 回 `{}` 并真的变成 interrupted；
    /// 换一条连接拿同样的 id 去停，回 "expected active turn id X but found Y"）。
    ///
    /// 所以：
    ///   - 手机自己发起的回合 → 停得掉
    ///   - 电脑端发起的回合   → 停不掉，别给一个点了没用的停止键
    ///
    /// 之前不区分，一律给「停止」，点了静默失败 —— 就是用户报的
    /// "对话进行时暂停点了没用"。
    var canStop: Bool { busy && localTurn }
}

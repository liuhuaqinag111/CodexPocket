import Foundation

/// 一条"本地乐观插入"的用户消息，现在处于什么状态。
///
/// 三种，跟 Happy 的 `sending` / `sendsAfterThisTurn` / `sendFailed` 一一对应：
///   - `.sending`  已交给服务端，等确认
///   - `.queued`   服务端在忙，消息进了共享队列（本轮结束后执行）
///   - `.failed`   确定没发出去
enum SendState: Equatable {
    case sending(since: Date)
    case confirming
    case queued(since: Date)
    case failed(String)

    var isQueued: Bool { if case .queued = self { return true }; return false }
    var isFailed: Bool { if case .failed = self { return true }; return false }

    var since: Date? {
        switch self {
        case .sending(let d), .queued(let d): return d
        case .failed, .confirming: return nil
        }
    }
}

/// 状态行该不该显示。
///
/// **空闲发送 1 秒内不显示任何东西**（快就该无感），超过宽限期才写
/// "发送中…"；忙碌排队**立刻显示** —— 那条消息确实要等，
/// 不说清楚用户会以为丢了。
///
/// 这条规则是从 Happy 的 `PENDING_STATUS_GRACE_MS = 1_000` 搬过来的：
/// "Busy sends are labelled at once; idle/new-chat sends stay quiet
///  through a grace period and only show a status if acceptance is
///  actually taking time."
enum SendStatusLine {
    static let grace: TimeInterval = 1

    static func shouldShow(_ s: SendState?, now: Date = Date(),
                           grace: TimeInterval = SendStatusLine.grace) -> Bool {
        guard let s else { return false }
        switch s {
        case .queued, .failed, .confirming: return true
        case .sending(let since): return now.timeIntervalSince(since) >= grace
        }
    }

    static func text(_ s: SendState) -> String {
        switch s {
        case .sending: return "发送中…"
        case .confirming: return "正在确认是否送达，请勿重复发送"
        case .queued: return "已排队，尚未发送"
        case .failed(let why): return "没发出去：\(why)"
        }
    }
}

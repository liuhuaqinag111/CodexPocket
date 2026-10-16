import UIKit

/// 触感反馈。
///
/// 之前整个 App 一次触感都没有 —— 长按菜单弹出来、复制成功、发送出去
/// 这些动作在手感上完全没有回应。
enum Haptics {
    /// 轻点：复制、选中、开关。
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 成功：发送出去、会话跑完。
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// 失败：发不出去、连不上。
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

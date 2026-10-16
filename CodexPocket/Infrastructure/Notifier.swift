import Foundation
import UIKit
import UserNotifications

/// 回合完成通知。
///
/// 之前只有 App 开着才知道跑完了 —— 用户："哪个会话回答完成了我都看不出来"。
/// 这里在回合结束时发一条本地通知；App 在前台就不发（人正看着，别吵）。
/// 点通知进对应会话，走 `AppDelegate.onOpen` 回给 `AppCoordinator`。
@MainActor
enum Notifier {

    /// 请求权限。启动时调一次，系统只会弹一次。
    static func request() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// 最近一次真的发出去的通知（调试/测试用：`notifyState` 无障碍元素读它）。
    static var lastFired: String?
    /// 最近一次通知的正文（调试/测试用）。
    static var lastBody: String = ""
    /// 发出去时回调一次（AppCoordinator 拿它更新界面上的调试元素）。
    static var onFired: ((String) -> Void)?
    /// 最近一次投递失败的原因（没权限、被限流…）。
    static var lastError: String?
    /// 已经通知过的回合 id。同一个回合只响一次。
    ///
    /// 以前每 2.5 秒轮询一次、每轮都会走到 `turnDone`，靠 `lastNotifiedTurn`
    /// 在**单个会话内**去重 —— 换会话或重进就重置了，同一个回合可能响两三次。
    /// 通知要振动/亮屏，重复响是实打实的耗电。
    private static var firedTurns: [String] = []
    static func alreadyFired(_ key: String) -> Bool { firedTurns.contains(key) }
    static func markFired(_ key: String) {
        guard !key.isEmpty, !firedTurns.contains(key) else { return }
        firedTurns.append(key)
        if firedTurns.count > 200 { firedTurns.removeFirst(firedTurns.count - 200) }
    }
    /// 最近几次"回合结束判定"的轨迹（测试用：一条通知为什么发/没发）。
    static var trace: [String] = []

    /// 一个回合跑完了。
    ///
    /// - Parameters:
    ///   - threadId: 会话 id，点击通知要跳过去。
    ///   - title: 会话名（列表里显示的那个）。
    ///   - text: 助手最后一段话，太长就截断。
    static func turnDone(threadId: String, title: String, text: String) {
        // 前台不发：用户就在看这个 App。
        // CODEX_PHONE_NOTIFY_ALWAYS=1 时前台也发 —— 单独验证通知链路用，
        // 免得把"通知本身坏了"和"后台收不到事件"混在一起查。
        let always = ProcessInfo.processInfo.environment["CODEX_PHONE_NOTIFY_ALWAYS"] == "1"
        guard always || UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = title.isEmpty ? "Codex" : title
        c.body = String(text.prefix(160))
        c.sound = .default
        c.userInfo = ["threadId": threadId]
        // identifier 用**会话 id**，不用 UUID：同一会话跑完多次时，
        // 新通知会顶掉旧的那条，通知中心里每个会话只留最新一条。
        // 以前每次都是新 id，跑十个回合就堆十条，根本看不出哪个是哪个。
        let r = UNNotificationRequest(identifier: "turn-\(threadId)",
                                      content: c, trigger: nil)
        lastFired = title
        // 把正文长度也带出去：测试要能判定"通知里到底有没有内容"。
        // 以前只有 fired=<标题>，40 条空标题的通知也是"通过"。
        lastBody = String(text.prefix(160))
        onFired?(title)
        UNUserNotificationCenter.current().add(r) { err in
            if let err { Task { @MainActor in Notifier.lastError = err.localizedDescription } }
        }
    }
}

import AVFoundation
import BackgroundTasks
import Foundation
import UIKit

/// 切后台时把进程留在活动状态，否则 socket 被冻结。
///
/// 三层保活，缺一层就会出现"一切后台就断联"：
///   1. 启动就配好音频会话（等到 `scenePhase == .background` 才配，
///      系统可能已经把进程挂起，`setActive` 直接失败）。
///   2. 静音音频循环播放 —— 数据本身就是静音（8-bit 128），
///      所以 `volume` 给 1 也听不见，比 volume=0 更不容易被系统当成
///      "没有输出"而回收。
///   3. `beginBackgroundTask` 兜底：音频会话起来前那几秒靠它顶着。
///
/// 音频会话会被来电、闹钟、别的 App 抢占（中断），中断结束后
/// **必须自己重新激活** —— 以前没有这一段，被中断一次就再也回不来，
/// 表现就是"用一会儿就断联"。
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var configured = false
    private var running = false
    /// 系统按资源情况调度，不保证启动时间或持续运行。
    private var procTask: BGProcessingTask?
    static let procID = "com.liuhuaqiang.codexpocket.refresh"

    /// App 启动就调：把会话和中断监听先装上。
    func prepare() {
        let s = AVAudioSession.sharedInstance()
        if !configured || s.category != .playback || s.mode != .default {
            do {
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                configured = true
            } catch { return }
        }
        guard observers.isEmpty else { return }
        let c = NotificationCenter.default
        // 中断结束 / 路由变化 / 媒体服务重启：都可能让播放停掉，重来一遍。
        for name in [AVAudioSession.interruptionNotification,
                     AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(c.addObserver(forName: name, object: s, queue: .main) {
                [weak self] notification in
                guard let self else { return }
                if name == AVAudioSession.mediaServicesWereResetNotification {
                    self.configured = false
                    self.player = nil
                }
                guard self.running else { return }
                if name == AVAudioSession.interruptionNotification {
                    self.player?.pause()
                    guard Self.shouldResumeAfterInterruption(notification.userInfo) else { return }
                }
                self.prepare()
                self.play()
            })
        }
    }

    func start() {
        guard !running else { return }
        running = true
        prepare()
        beginTask()
        play()
        scheduleProcessing()
    }

    /// 仅提交请求；注册必须由 App 启动回调提前完成。
    private func scheduleProcessing() {
        guard running, handlerRegistered, procTask == nil else { return }
        let req = BGProcessingTaskRequest(identifier: Self.procID)
        req.requiresNetworkConnectivity = true
        req.requiresExternalPower = false
        req.earliestBeginDate = Date(timeIntervalSinceNow: 1)
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            // 模拟器 / 没配 BGTaskSchedulerPermittedIdentifiers 时会抛。
            // 这时候退回纯音频保活，不要崩。
            return
        }
    }

    private var handlerRegistered = false
    /// BGTaskScheduler 要求 handler 必须在 `didFinishLaunchingWithOptions`
    /// **返回之前**注册，晚了注册不上（系统直接抛异常）。
    /// 所以 App 启动时就要调一次，不能等切后台。
    func registerAtLaunch() { registerProcessingHandler() }

    private func registerProcessingHandler() {
        guard !handlerRegistered else { return }
        handlerRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.procID,
                                        using: .main) { [weak self] task in
            guard let self, self.running, let t = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.completeProcessing(success: true)
            self.procTask = t
            t.expirationHandler = { [weak self, weak t] in
                DispatchQueue.main.async {
                    guard let self, let t, self.procTask === t else { return }
                    self.completeProcessing(success: false)
                }
            }
        }
    }

    func stop() {
        guard running || procTask != nil || bgTask != .invalid else { return }
        running = false
        completeProcessing(success: true)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.procID)
        endTask()
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                      options: [.notifyOthersOnDeactivation])
    }

    private func completeProcessing(success: Bool) {
        let task = procTask
        procTask = nil
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: success)
    }

    static func shouldResumeAfterInterruption(_ info: [AnyHashable: Any]?) -> Bool {
        guard let type = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              type == AVAudioSession.InterruptionType.ended.rawValue,
              let raw = info?[AVAudioSessionInterruptionOptionKey] as? UInt else { return false }
        return AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
    }

    private func play() {
        guard running else { return }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setActive(true)
        } catch {
            // 激活失败（多半被别的 App 占着）：靠 beginBackgroundTask 顶一会儿，
            // 路由变化通知会再试一次。
            return
        }
        if let p = player, p.isPlaying { return }
        if player == nil {
            player = try? AVAudioPlayer(data: Self.silence(), fileTypeHint: "wav")
            player?.numberOfLoops = -1
            // 数据本身是静音，音量给满也不会响；给 0 反而可能被系统
            // 判成"无输出"而回收。
            player?.volume = 1
        }
        player?.play()
    }

    /// 兜底：拿到一段后台执行时间，音频会话起来前不会被立刻挂起。
    private func beginTask() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "codexpocket.keepalive") {
            [weak self] in self?.endTask()
        }
    }

    private func endTask() {
        guard bgTask != .invalid else { return }
        let t = bgTask
        bgTask = .invalid
        UIApplication.shared.endBackgroundTask(t)
    }

    /// 生成 1 秒静音 WAV。比往包里塞音频文件干净。
    private static func silence() -> Data {
        let rate = 8000, seconds = 1
        let samples = rate * seconds
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + samples))
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        le32(16); le16(1); le16(1)
        le32(UInt32(rate)); le32(UInt32(rate)); le16(1); le16(8)
        d.append(contentsOf: Array("data".utf8))
        le32(UInt32(samples))
        d.append(contentsOf: [UInt8](repeating: 128, count: samples))
        return d
    }
}

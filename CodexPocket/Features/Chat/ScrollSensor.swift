import SwiftUI
import UIKit

/// 观察外层 UIScrollView 的真实滚动状态，并在"该跟随时"**直接**把它钉到底。
///
/// 为什么不用 SwiftUI 手势：挂在 ScrollView 上的 DragGesture 会被
/// ScrollView 自己的 pan 吞掉（回调根本不触发），"用户正在翻历史"就传不出来，
/// 自动跟随会把用户死死钉在底部。
///
/// 为什么不用 `ScrollViewReader.scrollTo`：LazyVStack 是懒的，屏幕外的
/// 锚点还没被创建，scrollTo 会**静默失败**；再加上内容要过好几轮才定型
/// （缓存 → 首屏 → 量高度 → Markdown 排版 → 图片解码），只能靠定时器反复
/// 重试 —— 那就是"补滚慢半拍 / 上下乱滑 / 突然回到最上面"的来源。
/// 合并同一轮布局变化后再写 `contentOffset`，避免跟临时高度抢滚动位置。
///
/// 判据全在**滚动视图自己**身上，不看 SwiftUI 的几何：
///   `userAway` = 用户自己翻上去了（手指松开那一刻离底部还远）。
///   只有 `!userAway` 时才自动钉底。
struct ScrollSensor: UIViewRepresentable {
    struct Metrics {
        /// 离底部还有多远（0 = 正好贴住）。
        var gap: CGFloat
        /// 用户按着或惯性滚动中。
        var hold: Bool
        /// 停在底部。
        var atEnd: Bool
        /// 用户主动翻上去了（自动跟随已让路）。
        var away: Bool
        /// 视口高度。
        var viewport: CGFloat
        /// 内容总高。
        var content: CGFloat
        /// 原始滚动偏移，排查用。
        var offset: CGFloat
        /// 滚动视图类名，排查用（怕量到的是别人的 UIScrollView）。
        var kind: String
    }

    let onScroll: (Metrics) -> Void
    /// 用户翻上去之后想让界面做点什么（显示「回到最新」）。
    var onAway: ((Bool) -> Void)?
    /// 界面递增它 = 请求归位到最新（打开会话 / 点「回到最新」）。
    ///
    /// 必须由 SwiftUI 传进来。之前它是 `SensorView` 自己的属性，
    /// 界面加了 1 而这里永远读不到 —— 点「回到最新」什么都不发生（实测）。
    var followGen: Int = 0
    var holdGen: Int = 0

    func makeUIView(context: Context) -> SensorView {
        let v = SensorView()
        v.isUserInteractionEnabled = false
        v.onScroll = onScroll
        v.onAway = onAway
        return v
    }

    func updateUIView(_ v: SensorView, context: Context) {
        v.onScroll = onScroll
        v.onAway = onAway
        // 归位请求合并到下一轮主队列，不在 SwiftUI 更新或 KVO 布局中改偏移。
        v.followGen = followGen
        v.holdGen = holdGen
        // **绝不在这里重置 `away`**：SwiftUI 每帧都会调 updateUIView
        // （流式输出时一秒十几次），重置一次就把"用户翻上去了"这个状态
        // 抹掉，自动钉底立刻把他拽回底部 —— 就是用户报的
        // "每次回我消息的时候会自动回到最下面，我想看上面的消息都看不成"。
        // 归位只走 followGen 这一条显式通道（打开会话 / 点「回到最新」）。
    }

    final class SensorView: UIView, UIGestureRecognizerDelegate {
        var onScroll: ((Metrics) -> Void)?
        var onAway: ((Bool) -> Void)?
        /// 用户自己翻上去了：自动钉底让路，直到他滑回底部或点「回到最新」。
        var away = false
        var holdGen = 0 {
            didSet {
                if holdGen != oldValue { away = true; scheduleReport() }
            }
        }
        /// 界面递增它表示"请回到最新"（打开会话 / 点按钮）。
        var followGen = 0 {
            didSet { if followGen != oldValue { scheduleReport() } }
        }
        private var lastGen = 0
        private var reportPending = false
        private weak var target: UIScrollView?
        private var ctx = 0
        private var observers: [NSObjectProtocol] = []
        private var poll: Timer?
        private var fastPoll: Timer?
        private var wasHold = false
        private lazy var keyboardTap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            return tap
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
            stopTimers()
            observeApp()
            guard window != nil else { return }
            startSlowPoll()
        }

        /// 常驻低频轮询：KVO 只在"值变了"时回调，而贴住底部不动时
        /// contentOffset 不变（只有内容在长），读到的尺寸会一直停在旧值。
        ///
        /// 0.2 秒 → 1 秒：这个定时器唯一的作用是让探针里的 `ch=`（内容高）
        /// 保持新鲜，界面本身用的是 KVO 那条路（`contentSize` 一变就回调，
        /// 自动钉底不受影响）。5Hz 的常驻唤醒在手机上是一笔实打实的电。
        private func startSlowPoll() {
            poll?.invalidate()
            poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                [weak self] _ in
                guard let self, self.target != nil else { return }
                self.scheduleReport()
            }
        }

        private func stopTimers() {
            poll?.invalidate(); poll = nil
            fastPoll?.invalidate(); fastPoll = nil
        }

        /// 切后台停掉 5Hz 轮询。
        ///
        /// 这个定时器从 view 进窗口起就一直跑（每 0.2 秒读一次滚动几何）。
        /// 保活开着时进程在后台还活着、RunLoop 还在跑，于是**屏幕黑着也一直醒**
        /// —— 用户报的「太耗电了」。回前台再起来。
        private func observeApp() {
            guard observers.isEmpty else { return }
            let c = NotificationCenter.default
            observers.append(c.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                self?.stopTimers()
            })
            observers.append(c.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                           object: nil, queue: .main) { [weak self] _ in
                guard let self, self.window != nil, self.poll == nil else { return }
                self.startSlowPoll()
            })
        }

        /// 沿 superview 往上找包着自己的 UIScrollView。
        func attach() {
            var v: UIView? = superview
            while let cur = v, !(cur is UIScrollView) { v = cur.superview }
            guard let sv = v as? UIScrollView, sv !== target else { return }
            if let old = target {
                old.removeObserver(self, forKeyPath: "contentOffset")
                old.removeObserver(self, forKeyPath: "contentSize")
                old.removeObserver(self, forKeyPath: "bounds")
                old.removeObserver(self, forKeyPath: "adjustedContentInset")
            }
            keyboardTap.view?.removeGestureRecognizer(keyboardTap)
            sv.addGestureRecognizer(keyboardTap)
            target = sv
            sv.addObserver(self, forKeyPath: "contentOffset", options: [.new], context: &ctx)
            // contentSize 也必须盯：贴住底部不动时 contentOffset 不变，
            // 只有内容在长（流式输出），不盯它就读不到内容总高（实测冻在首屏高度）。
            sv.addObserver(self, forKeyPath: "contentSize", options: [.new], context: &ctx)
            sv.addObserver(self, forKeyPath: "bounds", options: [.new], context: &ctx)
            sv.addObserver(self, forKeyPath: "adjustedContentInset", options: [.new], context: &ctx)
            scheduleReport()
        }

        private func scheduleReport() {
            guard !reportPending else { return }
            reportPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportPending = false
                guard let sv = self.target else { return }
                self.report(sv)
            }
        }

        override func observeValue(forKeyPath keyPath: String?,
                                   of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?,
                                   context: UnsafeMutableRawPointer?) {
            guard context == &ctx, let sv = target else { return }
            if sv.isTracking || sv.isDecelerating { wasHold = true }
            scheduleReport()
            // contentOffset 只在"变了"时通知；手指松开、惯性停下这些时刻
            // 偏移量不再变化，KVO 不会再来 —— 那样 userHold 会永远停在 true。
            // 所以按着/惯性期间补一个轮询，直到真的停下来。
            if sv.isTracking || sv.isDecelerating { startPoll() }
        }

        /// 手指按着/惯性期间提高采样率，让"用户正在翻"这件事及时传出去。
        private func startPoll() {
            fastPoll?.invalidate()
            fastPoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                [weak self] t in
                guard let self, let sv = self.target else { t.invalidate(); return }
                self.scheduleReport()
                if !sv.isTracking && !sv.isDecelerating { t.invalidate() }
            }
        }

        private func report(_ sv: UIScrollView) {
            let maxOff = max(0, sv.contentSize.height + sv.adjustedContentInset.bottom
                                - sv.bounds.height)
            // 内容还没长满一屏时没有"底部"可言，必须算作在底部。
            // 漏了这条判断会出大问题：此时 maxOff = 0，而 contentOffset.y 是
            // 顶部的负 inset（-47），`offset >= maxOff - 24` 判成"用户翻上去了"，
            // 于是自动跟随一进会话就被关掉，内容一路往上跑（用户报的"乱滑"）。
            let scrollable = sv.contentSize.height + sv.adjustedContentInset.top
                + sv.adjustedContentInset.bottom > sv.bounds.height + 1
            // 未满一屏时，永远处于有效可视区内（atEnd = true）
            let atEnd = !scrollable || (sv.contentOffset.y >= maxOff - 24 && sv.contentOffset.y <= maxOff + 50)

            let holding = sv.isTracking || sv.isDecelerating
            if holding { wasHold = true }
            // 跟随开关只在**手指松开那一刻**按用户停在哪决定。
            //
            // 不能拿"当前在不在底部"实时改它：内容自己在长、补滚又慢半拍，
            // 中途必然出现"离底部很远"的瞬间，那一下就会把跟随关掉、再也不
            // 恢复 —— 内容一路往上跑，就是"上下乱滑 / 突然回到最上面"。
            if wasHold && !holding {
                wasHold = false
                let now = !atEnd
                if now != away { away = now; onAway?(away) }
            }
            // 界面要求归位（打开会话 / 点「回到最新」）。
            if followGen != lastGen, !holding {
                lastGen = followGen
                away = false
                onAway?(false)
            }
            // 自动钉底：只在用户没翻上去、也没按着屏幕时。
            if !away && !holding { pin(sv, animated: false) }
            let settledAtEnd = !scrollable || (sv.contentOffset.y >= maxOff - 24
                && sv.contentOffset.y <= maxOff + 50)
            onScroll?(Metrics(gap: scrollable ? max(0, maxOff - sv.contentOffset.y) : 0,
                              hold: holding, atEnd: settledAtEnd, away: away,
                              viewport: sv.bounds.height, content: sv.contentSize.height,
                              offset: sv.contentOffset.y,
                              kind: String(describing: type(of: sv))))
        }

        /// 把内容钉到最新一条。**直接写 contentOffset**，不走 ScrollViewReader。
        private var pinning = false

        /// 彻底防止画面滑到空白处：
        /// 1. 内容未填满视口时（contentSize <= bounds.height），目标 offset 严格为顶部 inset（-top），绝不往负向多滑。
        /// 2. 只有在真正需要跟随、且不在手势中时，才把 offset 设置为 maxOff。
        private func pin(_ sv: UIScrollView, animated: Bool) {
            guard !pinning else { return }
            // 视口尺寸异常时不执行
            guard sv.bounds.height > 50, sv.contentSize.height > 10 else { return }
            
            let top = -sv.adjustedContentInset.top
            let scrollable = sv.contentSize.height + sv.adjustedContentInset.top + sv.adjustedContentInset.bottom > sv.bounds.height
            
            let target: CGFloat
            if !scrollable {
                target = top // 未满一屏时，死死锁在顶部起始位置，绝不往下滑空！
            } else {
                let maxOff = sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height
                target = max(top, maxOff)
            }
            
            guard abs(sv.contentOffset.y - target) > 0.5 else { return }
            pinning = true
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: animated)
            pinning = false
        }

        @objc private func dismissKeyboard() { window?.endEditing(true) }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextView || current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            poll?.invalidate()
            fastPoll?.invalidate()
            if let target {
                target.removeObserver(self, forKeyPath: "contentOffset")
                target.removeObserver(self, forKeyPath: "contentSize")
                target.removeObserver(self, forKeyPath: "bounds")
                target.removeObserver(self, forKeyPath: "adjustedContentInset")
            }
        }
    }
}

private struct HoldChatPositionKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}
extension EnvironmentValues {
    var holdChatPosition: () -> Void {
        get { self[HoldChatPositionKey.self] }
        set { self[HoldChatPositionKey.self] = newValue }
    }
}

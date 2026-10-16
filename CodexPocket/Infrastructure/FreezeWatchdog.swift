import Foundation

/// 主线程卡顿探针。
///
/// 「点了没反应 / 直接卡死」这类投诉，之前只能靠猜：模拟器上一切正常，
/// 真机上没人能量到主线程到底停了多久。这里放一个后台心跳 ——
/// 每 250ms 往主队列丢一个空块，量它多久才被执行。
///
///   - `maxStallMs`：本次启动以来最长的一次阻塞。
///   - `stage`：卡住的那一刻 App 正在干什么（几个关键路径会写它）。
///   - `stalls`：超过 500ms 的次数。
///
/// 只做只读统计，不改任何业务状态；关掉就一个字段都不写。
enum FreezeWatchdog {
    /// 超过这个时长才算一次卡顿。
    static let threshold: Double = 500

    private static let lock = NSLock()
    private static var _maxStall: Double = 0
    private static var _stalls = 0
    private static var _last: Double = 0
    private static var _stage = "idle"
    private static var _stageAt: Double = 0
    private static var started = false

    static var maxStallMs: Double { lock.lock(); defer { lock.unlock() }; return _maxStall }
    static var stallCount: Int { lock.lock(); defer { lock.unlock() }; return _stalls }
    static var lastStallMs: Double { lock.lock(); defer { lock.unlock() }; return _last }
    static var stage: String { lock.lock(); defer { lock.unlock() }; return _stage }

    /// 标记"现在在干什么"。卡住时看的就是这个值。
    static func mark(_ s: String) {
        lock.lock(); _stage = s; _stageAt = Date().timeIntervalSince1970; lock.unlock()
    }

    static func reset() {
        lock.lock(); _maxStall = 0; _stalls = 0; _last = 0; lock.unlock()
    }

    static func start() {
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        guard !already else { return }
        let q = DispatchQueue(label: "codexpocket.freeze")
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 0.25, leeway: .milliseconds(50))
        t.setEventHandler {
            let sent = Date()
            DispatchQueue.main.async {
                let ms = Date().timeIntervalSince(sent) * 1000
                lock.lock()
                _last = ms
                if ms > _maxStall { _maxStall = ms }
                if ms > threshold { _stalls += 1 }
                lock.unlock()
            }
        }
        t.resume()
        timer = t
    }

    private static var timer: DispatchSourceTimer?
}

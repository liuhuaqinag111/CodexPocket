import Foundation

/// 帧级日志。
///
/// 排查"流式没内容 / 回复看不见"这类问题时，最难的是一句话：
/// **帧没到，还是到了没画？** 这份日志把三类标记按时间写在同一个文件里：
///
///   FRAME  ← 服务端事件到达（method + itemId）
///   GATE   ← 回合门：这条被放行还是被丢弃，以及为什么
///   RENDER ← 这一条真的被画到屏幕上了
///
/// 默认关闭（开着会拖慢流式渲染）。设置里打开后写到
/// `Documents/frames.log`，封顶 256KB，超了留后一半。
enum FrameLog {
    static let flagKey = "debugFrames"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: flagKey) }

    private static let limit = 256 * 1024
    private static let q = DispatchQueue(label: "framelog")
    private static var handle: FileHandle?
    private static var written = 0
    /// 每个 item 已经收到多少条 delta —— 用来抽样，别让日志被 delta 刷爆。
    private static var seen: [String: Int] = [:]

    static var file: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("frames.log")
    }

    static func mark(_ kind: String, _ msg: String) {
        guard enabled else { return }
        let line = "\(stamp()) \(kind) \(msg)\n"
        q.async { append(line) }
    }

    /// 流式 delta 的抽样入口：每个 item 的第一条必记，之后每 25 条记一条。
    ///
    /// 不抽样的话 20 条/秒的 delta 两分钟就把 256KB 写满，
    /// 真正的"帧没到"反而被冲掉。
    static func markDelta(_ method: String, _ id: String) {
        guard enabled else { return }
        let n = (seen[id] ?? 0) + 1
        seen[id] = n
        if n == 1 || n % 25 == 0 { mark("FRAME", "\(method) \(id) #\(n)") }
    }

    private static func append(_ s: String) {
        if handle == nil {
            let f = file
            if !FileManager.default.fileExists(atPath: f.path) {
                FileManager.default.createFile(atPath: f.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: f)
            handle?.seekToEndOfFile()
            written = ((try? Data(contentsOf: f))?.count) ?? 0
        }
        guard let h = handle, let d = s.data(using: .utf8) else { return }
        h.write(d)
        written += d.count
        if written > limit { trim() }
    }

    /// 超限就只留后一半，别让日志把手机塞满。
    private static func trim() {
        try? handle?.close()
        handle = nil
        let f = file
        guard let all = try? String(contentsOf: f, encoding: .utf8) else { return }
        try? String(all.suffix(limit / 2)).write(to: f, atomically: true, encoding: .utf8)
        written = limit / 2
    }

    /// 把日志 POST 给桥接（`/framelog`），电脑上直接看文件。
    /// 手机上没有好用的查看器，也没法把文件拷出来。
    @MainActor
    static func upload(_ settings: PreferencesModel) async -> String? {
        let text = read()
        guard !text.isEmpty else { return nil }
        // 拆开写：`bridge` 是 @MainActor 隔离的，跟 `try? await` 混在同一个
        // guard 条件列表里 Xcode 14.3 会报 "expression is 'async'"（实测）。
        let url = settings.bridge(path: "/framelog")
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(text.utf8)
        guard let (_, resp) = try? await NetSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return text
    }

    static func read() -> String {
        // 先等写队列排空，否则刚 mark 完立刻读会读到空（测试里必踩）。
        q.sync {}
        return (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    }

    static func clear() {
        q.sync {
            try? handle?.close()
            handle = nil
            written = 0
            seen.removeAll()
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

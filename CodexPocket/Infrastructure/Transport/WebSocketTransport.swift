import Foundation

protocol RPCSocket: AnyObject {
    var state: URLSessionTask.State { get }
    var maximumMessageSize: Int { get set }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void)
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: RPCSocket {}

/// 与电脑端 app-server 的 WebSocket JSON-RPC 通道。
///
/// 只做四件事：连上、保持活着、发请求配对回包、把通知转发出去。
/// 不碰任何业务状态 —— 会话列表和消息都在各自的 AppCoordinator 里。
final class WebSocketTransport: NSObject {

    enum State: Equatable {
        case idle
        case connecting
        case ready
        case reconnecting(Int)
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "未连接"
            case .connecting: return "连接中"
            case .ready: return "已连接"
            case .reconnecting(let n): return "重连中 \(n)"
            case .failed(let m): return m
            }
        }
        var isReady: Bool { self == .ready }
    }

    /// 通知：服务端主动下发的（turn/*、item/*、thread/*）。
    var onNotification: ((String, JSONDict) -> Void)?
    /// 服务端请求审批。回包由上层决定。
    var onApproval: ((Approval) -> Void)?
    var onUserInput: ((ServerQuestionRequest) -> Void)?
    var onState: ((State) -> Void)?
    var onSendFailure: ((String) -> Void)?

    var state: State = .idle {
        didSet { if state != oldValue { onState?(state) } }
    }

    var task: RPCSocket?
    let incoming = DispatchQueue(label: "CodexPocket.IncomingJSON", qos: .userInitiated)
    let makeTask: ((URLRequest) -> RPCSocket)?
    /// 本次连接尝试是什么时候开始的（`shouldReopen` 用它算握手已经花了多久）。
    var attemptStarted: Date?
    lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        // WebSocket 是长连接，`timeoutIntervalForRequest` 会当成空闲超时用 ——
        // 20 秒对一条"十几秒才有一个 tick"的链路太紧，正常空闲也会被掐。
        // 判活交给 probe / 心跳，不靠这个。
        cfg.timeoutIntervalForRequest = 3600
        // delegate 用来做证书固定：直连 IP 时服务端是自签证书，
        // 系统链校验过不了，靠内置指纹认。
        return URLSession(configuration: cfg, delegate: NetSession.Pinner(), delegateQueue: nil)
    }()
    var seq = 0
    var waiters: [Int: (Result<Any, Error>) -> Void] = [:]
    var serverRequestIDs: [Int: String] = [:]
    var serverRequestSequence = -1_000_000_000
    var url: URL?
    var token = ""
    var endpointIdentity = UUID().uuidString
    var connectionIdentity: String { endpointIdentity }
    /// 用户想不想连着。主动断开后不再重连。
    var want = false
    var suspended = false
    var retryTimer: Timer?
    var retryDelay: TimeInterval = 0.4
    var retryCount = 0
    /// 握手看门狗：URLSession 连不上时不会报错，会一直挂着。
    var handshakeTimer: Timer?
    var heartbeat: Timer?
    /// 最近一次**收到**任何东西的时间。
    ///
    /// 这个值在 URLSession 的 delegate 队列上写（`handle` 由 `receive`
    /// 回调驱动），却在主队列上读（探活的超时检查）—— 裸 `var` 跨队列读写
    /// 是数据竞争，读到的可能是旧值，于是**活链路被判成死链**、
    /// 自己把好端端的连接拆掉重连。加锁修掉。
    let pongLock = NSLock()
    var _lastPong = Date()
    var socketGeneration = 0
    var lastPong: Date {
        get { pongLock.lock(); defer { pongLock.unlock() }; return _lastPong }
        set { pongLock.lock(); defer { pongLock.unlock() }; _lastPong = newValue }
    }
    /// 连续探活失败次数。**一次失败不拆链路**：网络路径刚变、
    /// 或者上行正好挤了一下，都会让一次探活打空，
    /// 而链路其实好好的 —— 拆了就是"动不动就断"。
    var probeFails = 0
    var probeInFlight = false
    /// 当前这条链路是什么时候建起来的（设置页显示"已连接 N 分钟"）。
    var connectedSince: Date?
    /// 累计掉线次数。用来判断"一直断链"到底是链路问题还是自己拆的。
    var drops = 0
    /// 最近一次断开的原因。只用于诊断（跟着心跳发给桥接，写进 agent.log）。
    ///
    /// 为什么要留这个：日志里只能看到 `close code=1006`，
    /// 分不清是"对端掐的"还是"我们自己探活误判拆的"——
    /// 465 次断线里有多少是误判，之前根本无从判断。
    var lastDrop = ""
    /// 已经**连上过**（initialize 成功过）的次数。用来判断"还没连上"
    /// 和"连上又断了"。
    var connects = 0

    struct DiagnosticSnapshot: Equatable {
        let stateLabel: String
        let drops: Int
        let connects: Int
        let lastDropReason: String
        let idleSeconds: Int
        let connectedDurationSeconds: Int?

        var summaryLine: String {
            if let dur = connectedDurationSeconds {
                return "已连 \(dur)s · 掉线 \(drops) · 距上次收包 \(idleSeconds)s"
            }
            return "状态: \(stateLabel) · 掉线 \(drops) · 原因: \(lastDropReason)"
        }
    }

    static func reconnectCountdownText(secondsRemaining: Int) -> String {
        if secondsRemaining <= 0 { return "正在连接…" }
        return "\(secondsRemaining)秒后重试"
    }

    func recordIncomingTraffic(at date: Date = Date()) {
        lastPong = date
    }

    func diagnosticSnapshot(now: Date = Date()) -> DiagnosticSnapshot {
        let idle = max(0, Int(now.timeIntervalSince(lastPong)))
        let dur = connectedSince.map { max(0, Int(now.timeIntervalSince($0))) }
        let reason = lastDrop.isEmpty ? "-" : lastDrop
        return DiagnosticSnapshot(stateLabel: state.label,
                                  drops: drops,
                                  connects: connects,
                                  lastDropReason: reason,
                                  idleSeconds: idle,
                                  connectedDurationSeconds: dur)
    }


    /// 直连 IP 时用的服务端证书指纹（SHA256，十六进制，大写无冒号）。
    ///
    /// 为什么需要：阿里云对"未备案域名解析到它的 IP"做 SNI 拦截
    /// （实测 SNI=czw.kdns.fr 直连 20 次被 RST 19 次，换成别的 SNI 或
    /// 不带 SNI 就放行）。所以 App 改成直连 IP —— 实测 iOS 连 IP 时
    /// ClientHello 里**根本没有 server_name 扩展**（tcpdump 抓包确认），
    /// 阿里云无从识别，链路就通了（建连 279ms、往返 244ms，
    /// 而走 Cloudflare 是 1425ms）。
    ///
    /// 代价是 IP 直连没有可信任的证书（Let's Encrypt 不签发 IP 证书），
    /// 所以服务端用一张带 `IP:8.148.8.23` 的自签证书，
    /// App 这边只认这一枚指纹 —— 不装描述文件，也不放行任意证书。
    static let pinnedCertSHA256 = "755AB119DE8DE610678C0EA90C3AF433E10A371BAA9214E62DC973B348CA2EC6"

    struct RPCError: LocalizedError, CustomNSError {
        let message: String
        let code: Int?
        init(message: String, code: Int? = nil) {
            self.message = message
            self.code = code
        }
        var errorDescription: String? { message }
        static let errorDomain = "CodexPocket.JSONRPC"
        var errorCode: Int { code ?? 0 }
        var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
    }

    init(makeTask: ((URLRequest) -> RPCSocket)? = nil) {
        self.makeTask = makeTask
        super.init()
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - 连接

    func connect(url: URL, token: String) {
        if self.url != url || self.token != token {
            endpointIdentity = UUID().uuidString
            disconnect()
        }
        self.url = url
        self.token = token
        want = true
        suspended = false
        retryDelay = 1
        retryCount = 0
        open()
    }

    func disconnect() {
        want = false
        suspended = false
        retryTimer?.invalidate(); retryTimer = nil
        handshakeTimer?.invalidate(); handshakeTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        retryDelay = 1
        retryCount = 0
        detachSocket()
        connectedSince = nil
        attemptStarted = nil
        probeInFlight = false
        probeFails = 0
        state = .idle
        failWaiters("已断开")
    }

    func suspend() {
        let resumeWanted = want
        disconnect()
        want = resumeWanted
        suspended = true
    }

    private func detachSocket() {
        let old = task
        task = nil
        pongLock.lock(); socketGeneration += 1; pongLock.unlock()
        serverRequestIDs.removeAll()
        old?.cancel(with: .goingAway, reason: nil)
    }

    func resume() {
        suspended = false
        reconnectNow()
    }

    /// 要不要真的重建 socket。
    ///
    /// **关键：在途的握手不能被拆。** `reconnectNow()` 会被"发送失败重试"
    /// 那条路每 1.5 秒调一次（`ConversationModel.startTurn` / `ThreadListModel.create`），
    /// 而一次握手本来就要 1~2 秒 —— 以前每次调用都 cancel + 重开，
    /// 结果是**越重试越连不上**，一直卡在握手里，日志上就是
    /// 一串活不过几秒的 `code=1006`。真机实测到
    /// `lastDrop = init:连接已断开` 就是这个循环。
    static func shouldReopen(ready: Bool, hasTask: Bool, taskRunning: Bool,
                             attemptAge: TimeInterval?,
                             grace: TimeInterval = 8) -> Bool {
        if ready { return false }
        guard hasTask, taskRunning else { return true }
        guard let age = attemptAge else { return true }
        return age >= grace     // 握了太久还没成，才值得推倒重来
    }

    /// 回前台 / 网络切换后立刻重连，不等退避。
    func reconnectNow() {
        guard want, !suspended else { return }
        guard Self.shouldReopen(ready: state.isReady,
                           hasTask: task != nil,
                           taskRunning: task?.state == .running,
                           attemptAge: attemptStarted.map { Date().timeIntervalSince($0) })
        else { return }
        retryTimer?.invalidate(); retryTimer = nil
        retryDelay = 1
        retryCount = 0
        open()
    }

    /// 探活：发一个应用层心跳，超时没回音就判定链路死了。
    ///
    /// 被系统挂起过的 socket 是"半开"的：不报错，发出去也没人收。
    /// 只能靠对端回声判定，控制帧 ping 在代理上不算数据。
    /// 回前台探活。
    ///
    /// socket 半开时 URLSession 不会报错：请求发得出去、永远不回。
    /// 以前这里先把 `lastPong` 置成 `sent` 再判 `lastPong < sent` —— 恒为假，
    /// **永远不会重连**。表现就是"切后台回来看到的是旧内容"：reload 的请求
    /// 掉进死 socket，界面停在后台前的样子。
    /// 现在只有"确实收到过东西"才算活着。
    /// 超时给 6 秒。原来是 2.5 秒 —— 手机在蜂窝上（或者 app-server 正
    /// 在推一条大消息）时，一个来回很容易超过 2.5 秒，于是**探活误判**，
    /// 明明好好的链路被自己拆掉重连。用户看到的就是"动不动就断"。
    func probe(timeout: TimeInterval = 6) {
        // 还没握手完成时不探活：那属于握手看门狗的职责，
        // 这里再插一脚只会把在途的握手拆掉。
        guard want, let t = task, state.isReady, !probeInFlight else { return }
        probeInFlight = true
        let sent = Date()
        // sendPing 只用来催系统发现死 TCP，**不能拿它的回包当"活着"的证据**：
        // 半开的 socket 上它照样立刻回成功（数据只是写进了内核缓冲）。
        // 判活只认"真的收到了东西"。
        task?.sendPing { _ in }
        send(["method": "bridge/ping", "params": ["ts": sent.timeIntervalSince1970,
                                                  "build": Build.stamp]])
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.want, self.task === t, self.state.isReady else { return }
            self.probeInFlight = false
            let got = self.lastPong > sent
            if got { self.probeFails = 0 }
            else { self.probeFails += 1 }
            switch Self.probeVerdict(gotSomething: got, fails: self.probeFails) {
            case .alive:
                return
            case .retry:
                // 第一次打空：再给一次机会。链路真的死了的话第二次也会打空，
                // 只多花一个 timeout，却省掉大量"好链路被误判拆掉"。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.task === t else { return }
                    self.probe(timeout: timeout)
                }
            case .reconnect:
                self.probeFails = 0
                self.scheduleReconnect("probe-timeout x2")
            }
        }
    }

    enum ProbeVerdict { case alive, retry, reconnect }

    /// 一次探活该得出什么结论。
    ///
    /// **一次打空不算死**：网络路径刚变、上行正好挤了一下，
    /// 都会让一次探活收不到回音，而链路其实好好的 —— 拆了就是
    /// "动不动就断"。要连续打空才判定死链。
    static func probeVerdict(gotSomething: Bool, fails: Int,
                             maxFails: Int = 2) -> ProbeVerdict {
        if gotSomething { return .alive }
        return fails >= maxFails ? .reconnect : .retry
    }

    func open() {
        guard want, !suspended, let url else { return }
        if let t = task, t.state == .running, state.isReady { return }
        // 正在握手就别再开一条 —— 见 shouldReopen 的注释。
        if !Self.shouldReopen(ready: state.isReady, hasTask: task != nil,
                         taskRunning: task?.state == .running,
                         attemptAge: attemptStarted.map { Date().timeIntervalSince($0) }) {
            return
        }
        retryTimer?.invalidate(); retryTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        handshakeTimer?.invalidate(); handshakeTimer = nil
        detachSocket()
        connectedSince = nil
        probeInFlight = false
        probeFails = 0
        failWaiters("连接已重建")
        guard want, !suspended, task == nil else { return }

        state = retryCount == 0 ? .connecting : .reconnecting(retryCount)
        attemptStarted = Date()
        var req = URLRequest(url: url)
        // 这条 request 上挂的是一个长连接，超时必须给足：
        // 30 秒对 WebSocket 来说太短，正常空闲也会被判超时。
        req.timeoutInterval = 3600
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = makeTask?(req) ?? session.webSocketTask(with: req)
        t.maximumMessageSize = 64 * 1024 * 1024
        task = t
        t.resume()
        listen()
        startHeartbeat()
        startHandshakeWatchdog()
        rpc("initialize", ["clientInfo": ["name": "codex-ios", "title": "Codex",
                                          "version": "1.0"],
                           "capabilities": ["experimentalApi": true]]) { [weak self] r in
            guard let self, self.task === t else { return }
            switch r {
            case .success:
                self.handshakeTimer?.invalidate(); self.handshakeTimer = nil
                self.retryDelay = 0.4
                self.retryCount = 0
                self.connectedSince = Date()
                self.connects += 1
                self.state = .ready
            case .failure(let e):
                let m = e.localizedDescription
                if m.contains("401") || m.lowercased().contains("unauthor") {
                    self.disconnect()
                    self.state = .failed("令牌无效")
                } else {
                    self.scheduleReconnect("init:" + m.prefix(40))
                }
            }
        }
    }

    func startHandshakeWatchdog() {
        guard let t = task else { return }
        handshakeTimer?.invalidate()
        // 20 秒：慢网络下握手（含 TLS）本来就可能要好几秒，
        // 10 秒会误判，然后 cancel + 重开，越连越连不上。
        handshakeTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.task === t else { return }
            self.handshakeTimer = nil
            guard self.want, !self.state.isReady else { return }
            self.scheduleReconnect("handshake-20s")
        }
    }

    /// 1s → 2s → 4s → 8s，封顶 15s，一直试到连上。
    func scheduleReconnect(_ why: String = "?") {
        guard want, !suspended, retryTimer == nil else { return }
        lastDrop = why
        handshakeTimer?.invalidate(); handshakeTimer = nil
        heartbeat?.invalidate(); heartbeat = nil
        detachSocket()
        attemptStarted = nil
        probeInFlight = false
        probeFails = 0
        retryCount += 1
        if connectedSince != nil { drops += 1 }
        connectedSince = nil
        let delay = retryDelay * Double.random(in: 0.85...1.15)
        retryDelay = min(retryDelay * 1.8, 6)
        state = .reconnecting(retryCount)
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.retryTimer = nil
            self?.open()
        }
        failWaiters("连接已断开")
    }

    func failWaiters(_ why: String) {
        guard !waiters.isEmpty else { return }
        // 先取快照再清空：回调里可能又触发重连，会再次走到这里。
        let pending = waiters
        waiters.removeAll()
        for (_, w) in pending { w(.failure(RPCError(message: why))) }
    }

    func startHeartbeat() {
        guard let t = task else { return }
        heartbeat?.invalidate()
        lastPong = Date()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.task === t else { return }
            // 45 秒 = 连丢 3 次桥接的 15s 心跳才判定死链。
            // 原来是 22 秒 —— 只要一次 tick 迟到（主线程忙、网络抖一下）
            // 就会误判成死链。
            if Date().timeIntervalSince(self.lastPong) > 45 {
                self.scheduleReconnect("heartbeat-45s")
                return
            }
            t.sendPing { _ in }
            self.send(["method": "bridge/ping",
                       "params": ["ts": Date().timeIntervalSince1970,
                                  "build": Build.stamp,
                                  "drops": self.drops,
                                  "connects": self.connects,
                                  "why": self.lastDrop]])
        }
    }

    func listen() {
        guard let t = task else { return }
        pongLock.lock(); let generation = socketGeneration; pongLock.unlock()
        t.receive { [weak self] result in
            // **先在这里记活，再跳主队列。**
            //
            // `handle()` 是在主队列上跑的，而它开头那句 `lastPong = Date()`
            // 因此要等主线程空出来。主线程一忙（展开长回合实测堵 2.4 秒，
            // 真机更久），`lastPong` 就一直不更新 —— 心跳定时器一看
            // "45 秒没收到东西"就判定死链、自己把好链路拆掉重连。
            // 桥接日志里 `lastDrop = heartbeat-45s` 今天 64 次就是这么来的。
            // 收到的字节本身就是"链路活着"的证据，记在 delegate 队列上。
            if case .success = result, let self {
                self.pongLock.lock()
                if self.socketGeneration == generation { self._lastPong = Date() }
                self.pongLock.unlock()
            }
            switch result {
            case .failure(let e):
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.task === t else { return }
                    if self.want { self.scheduleReconnect("recv:" + e.localizedDescription.prefix(40)) }
                }
            case .success(let msg):
                let text: String?
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                self?.incoming.async { [weak self] in
                    guard let text, let data = text.data(using: .utf8),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONDict else {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.task === t else { return }
                            self.listen()
                        }
                        return
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.task === t else { return }
                        self.handleObject(object)
                        if self.task === t { self.listen() }
                    }
                }
            }
        }
    }
}

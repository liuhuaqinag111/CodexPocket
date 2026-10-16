import Combine
import Foundation
import Network
import SwiftUI

/// 把各层拼起来：通道 + 四个状态域 + 前后台生命周期。
///
/// 视图只持有这一个对象，从它的 `list` / `chat` / `settings` 上读状态。
@MainActor
final class AppCoordinator: ObservableObject {

    let settings: PreferencesModel
    let rpc = WebSocketTransport()
    let cache: SnapshotCache
    let conversationRepository: ConversationRepository
    let threadRepository: ThreadRepository
    let inputRepository: InputRepository
    let fileRepository: FileRepository
    let workspaceRepository: WorkspaceRepository
    let list: ThreadListModel
    let chat: ConversationModel
    let composer: ComposerModel
    let voice: VoiceModel

    /// 连接状态（界面顶部那一行）。
    @Published var state: WebSocketTransport.State = .idle
    @Published var banner: String?
    /// 最近一次通知的状态，测试和无障碍元素读它。
    @Published var notifyState = "fired=- err=-"
    /// 左侧抽屉（会话列表）开着吗。ChatGPT 是会话页为根 + 抽屉拉出列表，
    /// 不是「列表页 push 进会话」。
    @Published var showDrawer = false
    /// 界面上真正显示的那条提示。
    ///
    /// 三个状态域（AppCoordinator / ConversationModel / ThreadListModel）都会报错，但以前
    /// RootView 只读 `store.banner` —— chat/list 里的
    /// "没发出去：…"、"建不了新会话：…" 从来没显示过，
    /// 用户看到的就是"点了没反应"。
    var activeBanner: String? { banner ?? chat.banner ?? list.banner }

    func clearBanner() {
        banner = nil
        chat.banner = nil
        list.banner = nil
    }

    /// 列表页上的「项目」「库」入口。
    @Published var showProjects = false
    @Published var showLibrary = false
    @Published var needsPairing = false
    @Published var showPairing = false
    @Published var pairingCandidate: PairingPayload?
    @Published var pairingError: String?

    private var pathMonitor: NWPathMonitor?
    private var pathProbe: DispatchWorkItem?
    private var isBackground = false
    private var pendingApprovals: [Int: Approval] = [:]
    private var pendingUserInputs: [Int: ServerQuestionRequest] = [:]
    private var composerAction: ComposerModel.Action = .idle
    private var chatProjectionScheduled = false
    /// 子 AppCoordinator 的变化要冒泡到 AppCoordinator 自己，否则只观察 AppCoordinator 的视图收不到
    /// 嵌套 ObservableObject 的更新（会话列表会一直停在"载入中"）。
    private var subs = Set<AnyCancellable>()
    /// 调试用：启动时自动打开某个会话（`CODEX_PHONE_OPEN=<id>`）。
    /// 截图和回归测试要靠它，省掉"手点进会话"这一步。
    private(set) var pendingOpen = ProcessInfo.processInfo.environment["CODEX_PHONE_OPEN"]
    private var openRequestGeneration = 0
    /// `pendingOpen` 已经被消费过了。
    ///
    /// `pendingOpen` 是 `let` 语义的一次性意图：环境变量注进来的那个会话
    /// 打开一次就完了。可它以前被赋成 `nil`，而 `list.$threads` 的 sink
    /// 里 `guard let id = self.pendingOpen` 之后紧接着 `self.open(t)` ——
    /// **每来一次列表更新就会重新 open 一次**（`threads` 一次会话能被
    /// 写好几遍：加载、改名、切项目…）。表现是"每次发消息会话都重开一遍"。
    private var pendingOpenDone = false

    init(transport: RPCTransport? = nil, cache: SnapshotCache? = nil,
         preferences: PreferencesModel? = nil) {
        settings = preferences ?? PreferencesModel()
        needsPairing = !settings.isConfigured
        let transport = transport ?? rpc
        self.cache = cache ?? Self.makeCache(namespace: settings.url?.absoluteString ?? "")
        conversationRepository = ConversationRepository(transport: transport, cache: self.cache)
        threadRepository = ThreadRepository(transport: transport)
        inputRepository = InputRepository(transport: transport)
        fileRepository = FileRepository(transport: transport)
        workspaceRepository = WorkspaceRepository(transport: transport)
        list = ThreadListModel(repository: threadRepository, settings: settings)
        chat = ConversationModel(repository: conversationRepository, settings: settings, list: list)
        composer = ComposerModel(repository: inputRepository, list: list, chat: chat, settings: settings)
        voice = VoiceModel(list: list)
        composer.onSubmit = { [weak self] in self?.voice.stopDictationIfNeeded() }
        Notifier.onFired = { [weak self] t in
            self?.notifyState = "fired=\(t) body=\(Notifier.lastBody.count) err=- tr=\(Notifier.trace.suffix(4).joined(separator: "|"))"
        }
        // 听写结果并进输入框。
        voice.onStarted = { [weak self] in self?.composer.beginDictation() }
        voice.onStopped = { [weak self] in self?.composer.endDictation() }
        voice.onText = { [weak self] heard in
            self?.composer.applyDictation(heard)
        }
        list.$currentID.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.voice.stopDictationIfNeeded()
            Task { @MainActor [weak self] in self?.restoreApprovals() }
        }.store(in: &subs)

        // 列表拉回来就预热前几个会话（见 ConversationModel.prefetch 的注释）。
        list.onLoaded = { [weak self] ids in
            Task { @MainActor in
                guard let self, !self.isBackground else { return }
                self.chat.prefetch(ids)
            }
        }
        list.onFirstMessage = { [weak self] id, text in
            guard let self else { return }
            if self.list.currentID != id { self.chat.open(id: id) }
            self.composer.text = text
            self.composer.submit()
        }
        composerAction = composer.action
        chat.objectWillChange.sink { [weak self] _ in
            guard let self, !self.chatProjectionScheduled else { return }
            self.chatProjectionScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.chatProjectionScheduled = false
                let action = self.composer.action
                if self.composerAction != action {
                    self.composerAction = action
                    self.composer.objectWillChange.send()
                }
            }
        }.store(in: &subs)
        chat.$banner.dropFirst().removeDuplicates().sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subs)
        for o in [list.objectWillChange,
                  composer.objectWillChange, voice.objectWillChange,
                  settings.objectWillChange] {
            o.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
        }
        list.$threads.combineLatest(list.$archived).sink { [weak self] rows, archived in
            guard let self, !self.pendingOpenDone, let id = self.pendingOpen,
                  let t = (rows + archived).first(where: { $0.id == id }) else { return }
            self.pendingOpenDone = true
            self.open(t)
        }.store(in: &subs)
        rpc.onState = { [weak self] st in
            Task { @MainActor in
                guard let self, self.rpc.state == st else { return }
                self.state = st
                if !st.isReady { self.chat.invalidateStreamContinuity() }
                // 连上了：把列表和当前会话补齐，并读一次额度。
                if st.isReady {
                    if !self.isBackground {
                        self.list.load()
                        // 断线期间攒下的内容要补回来（force 版：id 先对齐再重拉）。
                        if self.list.currentID != nil { self.chat.catchUp() }
                        self.resumePolling()
                    }
                    // 断线期间有一条消息的送达结果没定，重连后判定它。
                    if !self.isBackground { self.chat.confirmPending() }
                    // 离线期间攒下的消息，连上就发出去。
                    if !self.isBackground { self.composer.flushOutbox() }
                }
            }
        }
        chat.$busy.dropFirst().filter { !$0 }.sink { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isBackground else { return }
                self.composer.flushOutbox()
            }
        }.store(in: &subs)
        rpc.onNotification = { [weak self] m, p in
            Task { @MainActor in
                self?.chat.apply(m, p)
                if m == "thread/settings/updated" { self?.list.applyConfigurationEvent(p) }
                if m == "bridge/approvalResolved" { self?.clearResolvedRequest(p) }
                // 会话列表的元信息（名字、运行状态）跟着刷新。
                if m == "thread/name/updated", let id = p.str("threadId"),
                   let n = p.str("name") {
                    self?.list.setName(id, n)
                }
                if m == "thread/status/changed", let id = p.str("threadId"),
                   let type = p.dict("status")?.str("type") {
                    self?.list.setRunning(id, ThreadStatus.isRunning(type))
                }
                // 电脑端删了会话：本地立刻摘掉。
                // 不处理的话列表里会一直留着这条，点进去 "thread not loaded"。
                // 电脑端新建了会话：拉一次列表，让它在手机上出现。
                // 只带 id 不足以补出完整行（标题/时间/项目都要），所以重拉。
                //
                // **只拉第一页**，不要 `load()`。`load()` 会连项目、模型和
                // 全部页一起重拉（活跃 1 页 + 归档 3 页 = 4 个 thread/list，
                // 外加 model/list、project/list）—— 实测它每分钟被触发一次，
                // 白烧 6 个请求。新建的会话按 updatedAt 一定在第一页里。
                if m == "thread/started", self?.isBackground == false {
                    self?.list.fetchThreadsFirstPage()
                }
                if m == "thread/deleted", let id = p.str("threadId") {
                    self?.list.dropped(id)
                }
                if m == "thread/archived", let id = p.str("threadId") {
                    self?.list.markArchived(id, true)
                }
                if m == "thread/unarchived", let id = p.str("threadId") {
                    self?.list.markArchived(id, false)
                }
                // 回合跑完发通知：App 在后台也能知道是哪个会话好了。
                if m == "turn/completed", let tid = p.str("threadId") {
                    guard let self else { return }
                    let name = self.list.thread(tid)?.displayTitle ?? "Codex"
                    // 本地有就直接用（手机端自己发起的回合走事件流，有）。
                    let local = tid == self.list.currentID ? self.chat.lastAgentText() : ""
                    if !local.isEmpty {
                        Notifier.turnDone(threadId: tid, title: name, text: local)
                    } else {
                        // 电脑端发起的回合本地没有内容 —— 拉一次补上，
                        // 否则通知就是一条空白的"已完成"。
                        self.chat.fetchLastAgentText(tid) { text in
                            Task { @MainActor in
                                Notifier.turnDone(threadId: tid, title: name, text: text)
                            }
                        }
                    }
                }
            }
        }
        rpc.onApproval = { [weak self] req in
            Task { @MainActor in
                guard let self else { return }
                self.pendingApprovals[req.id] = req
                self.restoreApprovals()
            }
        }
        rpc.onUserInput = { [weak self] request in
            Task { @MainActor in
                guard let self else { return }
                self.pendingUserInputs[request.id] = request
                self.restoreApprovals()
            }
        }
        rpc.onSendFailure = { [weak self] m in
            Task { @MainActor in
                guard let self else { return }
                // **"还没连上电脑"不进全局横幅。**
                //
                // 它是链路正在重连时的瞬时状态，顶栏的连接指示灯已经在说
                // 这件事了。以前它被当成全局 banner 弹在屏幕底部 ——
                // 用户按发送的那一下正好撞在重连窗口里，看到的就是
                // 「发消息的那一下直接在底部报错」，而消息其实还在自动重发。
                // 真错误（服务端拒了、写超时）照旧弹。
                if m.contains("还没连上") { return }
                self.banner = m
            }
        }
    }

    static func makeCache(namespace: String) -> SnapshotCache {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return SnapshotCache(directory: root.appendingPathComponent("Snapshots"),
                             namespace: namespace,
                             legacyDirectory: root.appendingPathComponent("chat"))
    }

    func connect() {
        guard let u = settings.url, !settings.token.isEmpty else { return }
        prepareConnection(namespace: u.absoluteString)
        rpc.connect(url: u, token: settings.token)
        watchPath()
    }

    func previewPairing(_ input: String, present: Bool = false) {
        do {
            pairingCandidate = try PairingPayload.parse(input)
            pairingError = nil
        } catch {
            pairingCandidate = nil
            pairingError = error.localizedDescription
        }
        if present && !needsPairing { showPairing = true }
    }

    @discardableResult
    func confirmPairing() -> Bool {
        guard let pairing = pairingCandidate else { return false }
        composer.flushDraft()
        do { try settings.savePairing(pairing) }
        catch { pairingError = error.localizedDescription; return false }
        rpc.disconnect()
        needsPairing = false
        showPairing = false
        pairingCandidate = nil
        pairingError = nil
        clearBanner()
        connect()
        Notifier.request()
        return true
    }

    func prepareConnection(namespace: String) {
        if cache.namespace != namespace {
            list.connectionGeneration &+= 1
            composer.flushDraft()
            voice.stopDictationIfNeeded()
            rpc.disconnect()
            openRequestGeneration += 1
            pendingOpen = nil
            chat.close()
            chat.forgetAllTurns()
            chat.activeSubmissionIDs.removeAll()
            chat.uncertainSubmissionIDs.removeAll()
            chat.acceptedSubmissionIDs.removeAll()
            chat.completedTurnIDs.removeAll()
            chat.submissionChecks.removeAll()
            chat.lastCacheAt.removeAll()
            chat.prefetchGeneration += 1
            chat.prefetchRunning = nil
            chat.cacheRefreshInFlight.removeAll()
            pendingApprovals.removeAll()
            pendingUserInputs.removeAll()
            list.invalidateListReads()
            list.configurationReadSeq += 1
            list.configurationChanges += 1
            list.configurationRead = nil
            list.configurationInFlight = nil
            list.confirmedConfigurationID = nil
            list.configurationCallbacks.removeAll()
            list.projectReadSeq += 1
            list.modelReadSeq += 1
            list.searchSeq += 1
            list.searchTimer?.invalidate()
            list.threads = []; list.archived = []; list.projects = []; list.models = []
            list.pendingNew = [:]; list.searchHits = []; list.searchSnippets = [:]
            list.globalModel = ""; list.globalEffort = ""; list.globalEfforts = []
            list.filed = [:]
            list.fetchedOnce = false
            composer.loadDraft()
        }
        cache.setNamespace(namespace)
    }

    /// 网络切换（WiFi ↔ 蜂窝、进地铁）时 socket 会变成死连接：
    /// 不报错，但发出去没人收。以前 `pathMonitor` 声明了却从没用过，
    /// 只能等 15 秒的心跳超时才发现 —— 表现就是"用一会儿就断联"。
    /// 路径一变就立刻重连。
    private func watchPath() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        // 防抖：iOS 的网络路径会在"信号抖一下"时反复变（同一秒里
        // satisfied → 不 satisfied → satisfied）。以前每变一次就探活一次，
        // 探活失败就重连 —— 这是"动不动就断"的一个放大器。
        // 现在只在路径稳定 1.5 秒后探一次。
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.pathProbe?.cancel()
                self.pathProbe = nil
                guard path.status == .satisfied, !self.isBackground else { return }
                let w = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        guard let self, !self.isBackground else { return }
                        if self.rpc.state.isReady { self.rpc.probe() }
                        else { self.rpc.reconnectNow() }
                    }
                }
                self.pathProbe = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
            }
        }
        m.start(queue: DispatchQueue(label: "codexpocket.path"))
        pathMonitor = m
    }

    func disconnect() {
        voice.stopDictationIfNeeded()
        openRequestGeneration += 1
        pendingOpen = nil
        pathProbe?.cancel(); pathProbe = nil
        pathMonitor?.cancel(); pathMonitor = nil
        BackgroundKeeper.shared.stop()
        list.suspendReconcile()
        chat.stopRemoteWatch()
        rpc.disconnect()
    }

    deinit {
        pathProbe?.cancel()
        pathMonitor?.cancel()
    }

    /// "3 分 12 秒" / "1 小时 4 分"。设置页显示本次连接活了多久。
    static func duration(since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \((s % 3600) / 60) 分"
    }

    /// 打开会话：交给 chat，同时把当前项目提到列表最前。
    func open(_ t: Thread) {
        openRequestGeneration += 1
        pendingOpen = nil
        chat.open(t)
        composer.loadDraft()
        showDrawer = false
    }

    /// 通知与深链可先于列表到达；保留目标直到对应行加载完成。
    func requestOpenThread(_ id: String) {
        guard !id.isEmpty else { return }
        openRequestGeneration += 1
        let generation = openRequestGeneration
        let session = chat.openSeq
        pendingOpen = id
        if let thread = list.thread(id) { open(thread); return }
        threadRepository.readThread(id) { [weak self] result in
            Task { @MainActor in
                guard let self, self.openRequestGeneration == generation, self.pendingOpen == id else { return }
                guard self.chat.openSeq == session else { self.pendingOpen = nil; return }
                self.pendingOpen = nil
                switch result {
                case .success(let thread):
                    if self.list.thread(id) == nil { self.list.threads.insert(thread, at: 0) }
                    self.open(self.list.thread(id) ?? thread)
                case .failure(let error): self.banner = error.localizedDescription
                }
            }
        }
    }

    /// 列表页右下角那颗胶囊：**开一个新对话**。
    ///
    /// 它的图标就是铅笔（`square.and.pencil`），语义和顶栏那颗铅笔一样。
    /// 我上一版把它做成"回到上次的聊天" —— 用户："点进去还是别的会话，
    /// 不是新会话"。就是这里搞错了。
    func backToChat() {
        openRequestGeneration += 1
        pendingOpen = nil
        showDrawer = false
        composer.newThread()
    }

    func resolve(_ req: Approval, accept: Bool) {
        guard rpc.state.isReady else { banner = "连接恢复后再确认"; return }
        if !rpc.reply(to: req, result: ["decision": req.decision(accept: accept)]) {
            banner = "回复没发出去，连接恢复后重试"
        }
    }

    private func clearResolvedRequest(_ params: JSONDict) {
        let numeric = params.int("requestId"), wire = params.str("requestId")
        let matches: (Int, String?) -> Bool = { id, requestID in
            numeric == id || (wire != nil && wire == requestID)
        }
        let ids = pendingApprovals.values.filter { matches($0.id, $0.requestID) }.map(\.id)
            + pendingUserInputs.values.filter { matches($0.id, $0.requestID) }.map(\.id)
        for id in ids {
            pendingApprovals.removeValue(forKey: id)
            pendingUserInputs.removeValue(forKey: id)
            chat.approvals.removeAll { $0.id == id }
            chat.userInputs.removeAll { $0.id == id }
        }
    }

    private func restoreApprovals() {
        chat.approvals = pendingApprovals.values.filter {
            $0.threadId == nil || $0.threadId == list.currentID
        }.sorted { $0.id < $1.id }
        chat.userInputs = pendingUserInputs.values.filter {
            $0.threadId == list.currentID
        }.sorted { $0.id < $1.id }
    }

    func answerUserInput(_ request: ServerQuestionRequest, answers: [String: [String]]) {
        guard rpc.state.isReady else { banner = "连接恢复后再回答"; return }
        if !rpc.reply(to: request, answers: answers) {
            banner = "回复没发出去，连接恢复后重试"
        }
    }

    // MARK: - 生命周期

    func enterBackground() {
        guard !isBackground else { return }
        isBackground = true
        chat.remotePollingAllowed = false
        voice.stopDictationIfNeeded()
        pathProbe?.cancel(); pathProbe = nil
        // **所有轮询都停。**
        //
        // 这两个定时器以前只跟视图的 `onAppear` / `onDisappear` 绑着，
        // 切后台**不停** —— 而保活开着时进程还活着、RunLoop 还在跑，
        // 于是整夜在后台每 2.5 秒拉一次 turns、每 8 秒拉一次列表。
        // 用户报的「太耗电了」主要是这一段：屏幕黑着也在发请求。
        //
        // 保活只负责"别断链"（音频 + socket 心跳，都是本地的），
        // 跟"要不要轮询"是两件事。回前台时 `enterForeground` 会重新拉齐。
        list.suspendReconcile()
        chat.stopRemoteWatch()
        // **切后台不自动放锁。**
        //
        // 放锁 = 重启 app-server，代价是：进程内存里的排队消息全丢、
        // 正在飞的回包全丢、之后 10~20 秒连不上。
        //
        // 2026-10-07 教训：以前这里无条件调 `/release`，App 切后台时
        // 一秒触发三次，反复把 app-server 杀掉。用户下午发的几条消息正好
        // 打进那些 ECONNREFUSED 窗口里 —— 从来没到过服务端，永久丢失。
        //
        // 放锁改成用户显式操作（设置 → 「释放电脑端会话锁」）。
        // 少一点"自动"，换不回已经丢的消息，但至少不再丢。
        if settings.keepAlive {
            BackgroundKeeper.shared.start()
        } else {
            BackgroundKeeper.shared.stop()
            rpc.suspend()
        }
    }

    /// 让桥接重启 app-server，把手机端占着的会话写者锁放掉。
    ///
    func releaseWriterLocks() async -> String {
        let threadID = list.currentID
        let query = threadID.map { [URLQueryItem(name: "threadId", value: $0)] } ?? []
        guard let url = settings.bridge(path: "/release-writers", query: query) else { return "连接地址无效" }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        do {
            let (data, response) = try await NetSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with: data) as? JSONDict else {
                return "释放失败，请检查连接后重试"
            }
            if result.bool("released") == true {
                if let threadID { chat.desktopLockedThreads.remove(threadID); chat.objectWillChange.send() }
                else { chat.clearAllWriterLocks() }
            }
            return Self.writerReleaseFeedback(result)
        } catch { return "连接中断，未确认释放成功，请重试" }
    }

    static func writerReleaseFeedback(_ result: JSONDict) -> String {
        if result.bool("released") == true {
            if (result["writerWorkers"] as? NSNumber)?.intValue ?? 0 > 0 {
                return "仍有任务或请求未结束，空闲后会自动释放"
            }
            return "已释放空闲会话，连接保持正常"
        }
        switch result.str("reason") {
        case "active-turn": return "仍有回复正在生成，结束后会自动释放"
        case "cooldown": return "刚释放过，请稍后再试"
        default: return "当前状态还没确认，暂不释放；稍后再试"
        }
    }

    func enterForeground() {
        isBackground = false
        chat.remotePollingAllowed = true
        BackgroundKeeper.shared.stop()
        // 后台期间攒下的流式增量先落进列表：RunLoop 在后台不跑，
        // 定时刷新不触发，那些 delta 会一直躺在缓冲里。
        chat.flush()
        // 列表页还开着的话，把对账接回来（见 resumeReconcileIfWanted）。
        resumePolling()
        if rpc.state.isReady {
            rpc.probe()
            list.load()
            chat.confirmPending()
            composer.flushOutbox()
            if list.currentID != nil {
                // 后台期间跑完的回合，服务端不会补发通知（见 pollRemote 里的说明）。
                // 光 reload 还不够 —— 本地那条占位 id 跟服务端的真实 id 对不上，
                // ForEach 认 id 不认内容，补到了也渲染不出来。见 catchUp。
                chat.catchUp()
            }
        } else {
            rpc.resume()
        }
    }

    private func resumePolling() {
        list.resumeReconcileIfWanted()
        if let id = list.currentID { chat.startRemoteWatch(id) }
    }
}

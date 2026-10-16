import UIKit
import Foundation
import Combine

/// 输入区：草稿、待发图片、语音输入。
///
/// 草稿按会话分开存 —— 切出去再回来，写了一半的字还在。
@MainActor
final class ComposerModel: ObservableObject {
    @Published var text = "" {
        didSet {
            draftDirty = true
            scheduleDraftSave()
            // 只在可能触发补全时才重算（绝大多数按键走的是快路径）。
            if suggestionKind != .none || text.hasSuffix("/") || text.hasSuffix("@") {
                refreshSuggestions()
            }
        }
    }
    /// 待发图片的**本地**路径（只用于输入框上方的预览）。
    @Published var images: [String] = []
    /// 每张图在电脑端的路径（跟 `images` 一一对应）。
    /// 空串 = 还没传上去。发送时用的是这个，不是本地路径。
    @Published var remotePaths: [String] = []
    /// 正在上传的图片张数。>0 时不让发送。
    @Published var uploading = 0
    /// 上传失败的原因（给用户看）。
    @Published var uploadError: String?
    @Published var creatingThread = false
    /// 离线时排队的消息（连上后自动补发）。
    struct Outgoing: Codable {
        enum State: String, Codable { case queued, awaitingAcknowledgement, failed }
        let threadId: String
        let text: String
        let images: [String]
        let localID: String
        let mode: String
        var state: State = .queued
        init(threadId: String, text: String, images: [String], localID: String = "local-" + UUID().uuidString,
             mode: String = "send", state: State = .queued) {
            self.threadId = threadId; self.text = text; self.images = images; self.localID = localID
            self.mode = mode; self.state = state
        }
        private enum CodingKeys: String, CodingKey { case threadId, text, images, localID, mode, state }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            threadId = try c.decode(String.self, forKey: .threadId)
            text = try c.decode(String.self, forKey: .text)
            images = try c.decode([String].self, forKey: .images)
            localID = try c.decode(String.self, forKey: .localID)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "send"
            state = try c.decodeIfPresent(State.self, forKey: .state) ?? .queued
        }
    }
    @Published var outbox: [Outgoing] = [] {
        didSet { persistOutbox() }
    }
    private var outboxNamespace: String
    private var draftNamespace: String
    private var restoringOutbox = false
    private var activeOutgoingIDs: [String: Int] = [:]
    private var outboxCheckAt: [String: Date] = [:]
    private var outboxChecks = Set<String>()
    @Published var listening = false
    @Published var denied = false
    /// 补全面板里的候选（`/` 命令或 `@` 文件）。
    @Published var suggestions: [Suggestions.Item] = []
    @Published var suggestionKind: Suggestions.Kind = .none
    /// 正在补全的那个词在输入框里的区间。
    var pendingRange: Range<String.Index>?
    var pendingToken = ""
    /// 文件搜索的乱序保护：只认最后一次请求的回包。
    var fileSearchSeq = 0
    /// 草稿防抖的定时器。
    var draftTimer: Timer?
    /// 需要界面配合的命令回调（见 runCommand）。
    var onCommand: ((String) -> Void)?
    /// 提交正文前通知外层结束听写，避免迟到的识别结果回填已发送文本。
    var onSubmit: (() -> Void)?

    let repository: InputRepositoryProtocol
    let list: ThreadListModel
    let chat: ConversationModel
    let settings: PreferencesModel
    let d: UserDefaults
    var draftThreadID: String?
    var draftDirty = false
    var imageDrafts: [String: ([String], [String], Int)] = [:]
    var dictationBase: (threadID: String?, text: String)?

    func beginDictation() { dictationBase = (list.currentID, text) }
    func endDictation() { dictationBase = nil }
    func applyDictation(_ heard: String) {
        guard let base = dictationBase, base.threadID == list.currentID else { return }
        text = base.text + heard
    }
    var uploads: [UUID: (key: String, path: String)] = [:]
    private var uploadTargets: [UUID: (url: URL, namespace: String)] = [:]
    var uploadMedia: (Data, URL) async throws -> String = { try await MediaRepository.upload($0, to: $1) }

    init(repository: InputRepositoryProtocol, list: ThreadListModel, chat: ConversationModel,
         settings: PreferencesModel, defaults: UserDefaults = .standard) {
        self.repository = repository
        self.list = list
        self.chat = chat
        self.settings = settings
        self.d = defaults
        self.outboxNamespace = settings.url?.absoluteString ?? ""
        self.draftNamespace = settings.url?.absoluteString ?? ""
        self.draftThreadID = list.currentID
        if !draftNamespace.isEmpty, d.string(forKey: "draft.v2.legacyOwner") == nil {
            d.set(draftNamespace, forKey: "draft.v2.legacyOwner")
        }
        restoreOutbox()
        chat.onSubmissionStarted = { [weak self] id in
            guard let self, let index = self.outbox.firstIndex(where: { $0.localID == id }) else { return }
            self.outbox[index].state = .awaitingAcknowledgement
            self.activeOutgoingIDs[id] = self.chat.openSeq
        }
        chat.onSubmissionResolved = { [weak self] id, accepted in
            self?.submissionResolved(id, accepted: accepted)
        }
        chat.onPoll = { [weak self] in self?.reconcileOutbox() }
    }

    var canSend: Bool {
        guard uploading == 0 else { return false }
        if !images.isEmpty {
            return remotePaths.count == images.count && remotePaths.allSatisfy { !$0.isEmpty }
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 发送语义模式（对标 devctl/dshconsole）：
    /// `.auto`: 空闲时发送，生成中为 steer 插话
    /// `.queue`: 无论如何都加入队列（等待本回合结束）
    @Published var sendMode: SendMode = .auto
    enum SendMode: String, CaseIterable, Identifiable {
        case auto = "插话"
        case queue = "排队"
        var id: String { rawValue }
    }

    /// 最近一次 submit 判定的 action + 判定依据。只给探针读。
    var lastAction = "-"

    /// 有内容时是"发送/插话/排队"，生成中空着的时候是"停止"。
    enum Action { case send, steer, queue, stop, idle }
    var action: Action {
        if creatingThread { return .idle }
        if chat.configurationPreparing { return .idle }
        if chat.canStop {
            if canSend { return sendMode == .queue ? .queue : .steer }
            return .stop
        }
        if chat.busy && canSend {
            // 回合在跑、但**还不知道活动回合 id** 的那一小段窗口。
            // 不能退回普通发送：`turn/start` 会另起一个回合，
            // 服务端把这条用户消息回显回来，界面上就是两条一样的
            // （用户报的「一下发两个」）。等 id 到手了再走插话。
            //
            // **没有回合 id 也能插话**：`steer()` 会先问一次
            // `thread/turns/list` 拿 id 再插（`resolveActiveTurn`）。
            // 问不到、或者插话被服务端拒了，才落回共享队列。
            //
            // 以前这里在 id 未知时直接给「排队」，用户看到的就是
            // 「切回来还是排队」；而且电脑端占着时也一律排队 ——
            // 实测（2026-10-14，真桥接 62113 + 真服务端）：
            // 电脑端起着的回合，手机端 `turn/steer` 照样成功，
            // 插话那句会进模型并改变答复。
            // 占着只说明 `thread/resume` 不可用，不说明插话不可用。
            if sendMode == .queue { return .queue }
            return .steer
        }
        return canSend ? .send : .idle
    }

    func submit() {
        if let endpoint = repository.endpointURL, endpoint != settings.url {
            chat.banner = "连接地址已更改，请先在设置中重新连接"
            return
        }
        syncOutboxNamespace()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // `/命令`：本地执行，不当消息发出去。
        if t.hasPrefix("/"), t.count > 1 {
            let name = String(t.dropFirst()).split(separator: " ").first.map(String.init) ?? ""
            if runCommand(name) {
                text = ""
                dismissSuggestions()
                return
            }
        }
        // **先算 action 再判断**：`action` 在输入框为空 + 正在跑时是 `.stop`，
        // 如果把 `guard canSend` 放在前面，空输入框点停止就会被直接 return
        // 掉（`canSend` 是 false）—— 这就是用户报的"对话进行时暂停点了没用"！
        let act = action
        lastAction = "\(act) busy=\(chat.busy ? 1 : 0) lt=\(chat.localTurn ? 1 : 0) "
            + "stid=\(chat.serverTurnId?.suffix(4).description ?? "nil") "
            + "dl=\(chat.desktopLocked ? 1 : 0) cs=\(chat.canStop ? 1 : 0) "
            + "cp=\(chat.configurationPreparing ? 1 : 0) rdy=\(repository.isReady ? 1 : 0) "
            + "sm=\(sendMode.rawValue)"
        if act == .idle { return }
        if act == .stop {
            chat.interrupt()
            return
        }
        guard canSend else { return }
        guard let threadId = list.currentID else {
            onSubmit?()
            newThread(sendingDraft: true)
            return
        }
        onSubmit?()
        let imgs = remotePaths.filter { !$0.isEmpty }
        let mode: String
        switch act { case .steer: mode = "steer"; case .queue: mode = "queue"; default: mode = "send" }
        let localID = "local-" + UUID().uuidString
        let pending = Outgoing(threadId: threadId, text: t, images: imgs, localID: localID, mode: mode,
                                state: repository.isReady ? .awaitingAcknowledgement : .queued)
        outbox.append(pending)
        text = ""
        images = []
        remotePaths = []
        if !repository.isReady {
            return
        }
        activeOutgoingIDs[localID] = chat.openSeq
        switch act {
        case .send:
            chat.send(t, images: imgs, localID: localID)
        case .steer:
            chat.steer(t, images: imgs, localID: localID)
        case .queue:
            if let tid = list.currentID {
                chat.items.append(.user(id: localID, text: t, images: imgs))
                chat.enqueueRemote(threadId: tid, text: t, images: imgs, localId: localID)
            }
        case .stop, .idle:
            break
        }
    }

    func stop() { chat.interrupt() }

    /// 纯函数，不碰状态 —— 标 `nonisolated` 才能在任何线程调（测试要用）。
    nonisolated static func formatQuote(_ raw: String) -> String {
        let lines = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        let quoted = lines.map { "> " + $0 }.joined(separator: "\n")
        return quoted + "\n\n"
    }

    func appendQuote(_ raw: String) {
        let block = Self.formatQuote(raw)
        if text.isEmpty {
            text = block
        } else {
            text = block + text
        }
        Haptics.tap()
    }


    /// 显式新建只开空会话；空会话页按发送才提交草稿。
    func newThread(sendingDraft: Bool = false) {
        guard !creatingThread, !sendingDraft || canSend else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = remotePaths.filter { !$0.isEmpty }
        let origin = list.currentID
        let session = chat.openSeq
        flushDraft()
        creatingThread = true
        // 新会话用设置里的默认目录（留空 = `~`），**绝不沿用上一个会话**。
        //
        // 以前这里是 `chat.current?.cwd ?? 最近一个会话的 cwd ?? 默认` ——
        // 结果新会话落在旧项目目录里，用户看到"打开新会话是旧工作目录"。
        // 也不能干脆不传：不带 cwd 的 thread/start 被服务端兜成 `/`
        // （实测），等于让 agent 一上来扫全盘。
        list.create(cwd: settings.newThreadCwd,
                    model: list.modelForNewThread,
                    effort: list.effortForNewThread,
                    first: nil) { [weak self] id in
            guard let self else { return }
            self.creatingThread = false
            guard self.list.currentID == origin, self.chat.openSeq == session,
                  let id else { return }
            let localID = "local-" + UUID().uuidString
            if sendingDraft {
                self.outbox.append(Outgoing(threadId: id, text: t, images: imgs, localID: localID,
                                            state: .awaitingAcknowledgement))
                if self.text.trimmingCharacters(in: .whitespacesAndNewlines) == t { self.text = "" }
                self.images = []
                self.remotePaths = []
            }
            // 别要求 list.thread(id) 一定存在：新建的会话服务端列表还没落盘，
            // 以前这里 guard 失败就整个 return —— 表现就是"点了没反应"。
            self.list.currentID = id
            self.chat.open(id: id)
            if sendingDraft { self.activeOutgoingIDs[localID] = self.chat.openSeq }
            self.loadDraft()
            if sendingDraft { self.chat.send(t, images: imgs, localID: localID) }
        }
    }

    /// 连上之后把离线队列补发出去。
    func flushOutbox() {
        if let endpoint = repository.endpointURL, endpoint != settings.url { return }
        syncOutboxNamespace()
        reconcileOutbox()
        guard repository.isReady, !chat.configurationPreparing,
              chat.pendingSend == nil, let id = list.currentID,
              let index = outbox.firstIndex(where: { $0.threadId == id && $0.state != .failed }) else { return }
        if outbox[index].state == .awaitingAcknowledgement {
            let message = outbox[index]
            guard activeOutgoingIDs[message.localID] != chat.openSeq else { return }
            activeOutgoingIDs[message.localID] = chat.openSeq
            chat.restoreSubmission(threadID: message.threadId, localID: message.localID,
                                   text: message.text, images: message.images)
            return
        }
        guard outbox[index].state == .queued else { return }
        outbox[index].state = .awaitingAcknowledgement
        let message = outbox[index]
        activeOutgoingIDs[message.localID] = chat.openSeq
        // 回合在跑 → 插话（没有 id 时 `steer()` 会先问一次服务端）；
        // 只有用户显式选了排队，或者根本没回合在跑，才走别的路。
        let mode = message.mode == "queue" ? "queue"
            : chat.busy || chat.canStop ? "steer" : "send"
        switch mode {
        case "steer": chat.steer(message.text, images: message.images, localID: message.localID)
        case "queue": chat.enqueueRemote(threadId: id, text: message.text, images: message.images, localId: message.localID)
        default: chat.send(message.text, images: message.images, localID: message.localID)
        }
    }

    var hasFailedOutgoing: Bool { outbox.contains { $0.threadId == list.currentID && $0.state == .failed } }
    var unsentCount: Int { outbox.filter { $0.threadId == list.currentID && $0.state == .queued }.count }
    func clearFailedOutgoing() {
        let ids = Set(outbox.filter { $0.threadId == list.currentID && $0.state == .failed }.map(\.localID))
        outbox.removeAll { ids.contains($0.localID) }
        chat.items.removeAll { ids.contains($0.id) }
        for id in ids { chat.sendStates.removeValue(forKey: id); chat.failed.remove(id) }
    }

    func retryOutbox() {
        syncOutboxNamespace()
        for i in outbox.indices where outbox[i].threadId == list.currentID && outbox[i].state == .failed {
            outbox[i].state = .queued
        }
        flushOutbox()
    }

    func retry(_ id: String, text: String, images: [String]) {
        let queue = outbox.first(where: { $0.localID == id })?.mode == "queue"
        chat.retry(id, text: text, images: images, queue: queue)
    }

    func submissionResolved(_ id: String, accepted: Bool) {
        guard let index = outbox.firstIndex(where: { $0.localID == id }) else { return }
        activeOutgoingIDs.removeValue(forKey: id)
        outboxCheckAt.removeValue(forKey: id)
        if accepted {
            outbox.remove(at: index)
        } else { outbox[index].state = .failed }
        Task { [weak self] in self?.flushOutbox() }
    }

    // MARK: - 草稿

    func reconcileOutbox() {
        guard repository.isReady, repository.endpointURL == nil || repository.endpointURL == settings.url else { return }
        let namespace = outboxNamespace
        let now = Date()
        for message in outbox where message.state == .awaitingAcknowledgement {
            if let last = outboxCheckAt[message.localID], now.timeIntervalSince(last) < 20 { continue }
            guard outboxChecks.insert(message.localID).inserted else { continue }
            outboxCheckAt[message.localID] = now
            let mayConfirm = activeOutgoingIDs[message.localID] == nil || chat.uncertainSubmissionIDs.contains(message.localID)
            chat.repository.perform(.submissionStatus(["threadId": message.threadId,
                "clientUserMessageId": message.localID])) { [weak self] result in
                Task { @MainActor in
                    self?.applyOutboxCheck(result, message: message, namespace: namespace, mayConfirm: mayConfirm)
                }
            }
        }
    }

    private func applyOutboxCheck(_ result: Result<Any, Error>, message: Outgoing, namespace: String, mayConfirm: Bool) {
        guard outboxNamespace == namespace else { return }
        outboxChecks.remove(message.localID)
        guard outbox.contains(where: { $0.localID == message.localID && $0.state == .awaitingAcknowledgement }),
              case .success(let value) = result, let status = value as? JSONDict else { return }
        switch status.str("state") {
        case "accepted":
            chat.accept(message.localID)
        case "missing", "unknown":
            guard mayConfirm,
                  activeOutgoingIDs[message.localID] == nil || chat.uncertainSubmissionIDs.contains(message.localID) else { return }
            chat.activeSubmissionIDs.insert(message.localID)
            chat.confirmSubmission(threadId: message.threadId, localId: message.localID,
                                   text: message.text, images: message.images)
        default: break
        }
    }

    private var outboxKey: String { "outbox.v1." + outboxNamespace }

    private func persistOutbox() {
        guard !restoringOutbox, !outboxNamespace.isEmpty,
              let data = try? JSONEncoder().encode(outbox) else { return }
        d.set(data, forKey: outboxKey)
    }

    private func restoreOutbox() {
        restoringOutbox = true
        defer { restoringOutbox = false }
        outbox = d.data(forKey: outboxKey).flatMap {
            try? JSONDecoder().decode([Outgoing].self, from: $0)
        } ?? []
    }

    private func syncOutboxNamespace() {
        let namespace = settings.url?.absoluteString ?? ""
        guard namespace != outboxNamespace else { return }
        persistOutbox()
        outboxNamespace = namespace
        activeOutgoingIDs = [:]
        outboxChecks.removeAll()
        outboxCheckAt.removeAll()
        restoreOutbox()
    }

    var draftKey: String { "draft.v2." + draftNamespace + "." + (draftThreadID ?? "none") }

    private func restoredDraft() -> String {
        if let text = d.string(forKey: draftKey) { return text }
        guard d.string(forKey: "draft.v2.legacyOwner") == draftNamespace,
              let old = d.string(forKey: "draft." + (draftThreadID ?? "none")) else { return "" }
        d.set(old, forKey: draftKey)
        return old
    }

    /// 草稿防抖：停手 0.4 秒再写 UserDefaults。
    ///
    /// 以前每敲一个字都写一次 —— UserDefaults 是同步落盘的，
    /// 打一段长文会在主线程上攒出一串写盘。
    func scheduleDraftSave() {
        draftTimer?.invalidate()
        draftTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.saveDraft() }
        }
    }

    func saveDraft() {
        guard draftDirty else { return }
        d.set(text, forKey: draftKey)
        draftDirty = false
    }

    /// 立刻落盘（切会话 / 退到后台时调，别把草稿留在防抖窗口里）。
    func flushDraft() {
        draftTimer?.invalidate()
        saveDraft()
    }

    /// 切会话时把草稿换过来。
    func loadDraft() {
        syncOutboxNamespace()
        // 上一个会话的草稿可能还在防抖窗口里，先落盘再换。
        flushDraft()
        imageDrafts[draftKey] = (images, remotePaths, uploading)
        draftNamespace = settings.url?.absoluteString ?? ""
        draftThreadID = list.currentID
        text = restoredDraft()
        draftDirty = false
        let draft = imageDrafts[draftKey] ?? ([], [], 0)
        images = draft.0
        remotePaths = draft.1
        uploading = draft.2
        uploadError = nil
        dismissSuggestions()
        flushOutbox()
    }

    // MARK: - 图片上传

    private func enqueueUpload(_ path: String) {
        guard !images.contains(path) else { return }
        images.append(path)
        remotePaths.append("")
        startUpload(path)
    }

    /// 把本地图片传到电脑上，拿回一个电脑端真实存在的路径。
    ///
    /// 两个必须：
    ///   1. **走 HTTP，不走 JSON-RPC**。以前用 `fs/writeFile` 把 base64
    ///      塞进那条 WebSocket，可它十几秒就抖一次（agent.log 里 465 次
    ///      code=1006），在途的大包整个丢 —— 用户看到的就是
    ///      "图片上传失败：连接已断开"。HTTP 是独立连接，互不影响，
    ///      而且发原始字节不用 base64（少 33%）。
    ///   2. **要的是电脑上的路径**。手机临时目录
    ///      （`/var/mobile/.../tmp/img-xxx.jpg`）电脑上不存在，
    ///      `turn/start` 会整个回 "Invalid request: data did not match
    ///      any variant of untagged enum ImageReference"（实测）。
    func upload(_ path: String) {
        enqueueUpload(path)
    }

    func retryUpload(at index: Int) {
        guard images.indices.contains(index), index < remotePaths.count,
              remotePaths[index].isEmpty, uploading == 0 else { return }
        startUpload(images[index])
    }

    private func startUpload(_ path: String) {
        uploading += 1
        uploadError = nil
        let id = UUID()
        uploads[id] = (draftKey, path)
        guard settings.url?.absoluteString == draftNamespace,
              let url = settings.bridge(path: "/upload", query: [URLQueryItem(name: "name", value: (path as NSString).lastPathComponent)]) else {
            finishUpload(id, remote: nil, error: "连接目标已变化，请重新添加图片")
            return
        }
        uploadTargets[id] = (url, draftNamespace)
        Task { [weak self] in
            let data = await Task.detached { try? Data(contentsOf: URL(fileURLWithPath: path)) }.value
            guard let self else { return }
            guard let data else { self.finishUpload(id, remote: nil, error: "读不到这张图"); return }
            self.post(data, name: (path as NSString).lastPathComponent, id: id, attempt: 0)
        }
    }

    /// POST 原始字节到桥接的 `/upload`。失败就再试一次 ——
    /// 手机在蜂窝/WiFi 切换时第一条请求很容易打空。
    func post(_ data: Data, name: String, id: UUID, attempt: Int) {
        guard uploads[id] != nil else { return }
        guard let target = uploadTargets[id], target.namespace == settings.url?.absoluteString else {
            finishUpload(id, remote: nil, error: "连接目标已变化，请重试图片上传")
            return
        }
        Task { @MainActor in
            var remote: String?
            var why = "连接失败"
            do {
                remote = try await self.uploadMedia(data, target.url)
            } catch {
                why = error.localizedDescription
            }
            if let remote {
                self.finishUpload(id, remote: remote, error: nil)
                return
            }
            if attempt < 1 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.post(data, name: name, id: id, attempt: attempt + 1)
                return
            }
            self.finishUpload(id, remote: nil, error: "图片没传上去：\(why)")
        }
    }

    /// 传完（成功或失败）收尾。
    ///
    /// 失败图片保留在待发区；remotePaths 空值阻止发送，并允许重试。
    func finishUpload(_ id: UUID, remote: String?, error: String?) {
        uploadTargets.removeValue(forKey: id)
        guard let upload = uploads.removeValue(forKey: id) else { return }
        var draft = upload.key == draftKey ? (images, remotePaths, uploading)
            : imageDrafts[upload.key] ?? ([], [], 0)
        draft.2 = max(0, draft.2 - 1)
        if let i = draft.0.firstIndex(of: upload.path), i < draft.1.count {
            if let remote { draft.1[i] = remote }
            else { draft.1[i] = "" }
        }
        if upload.key == draftKey {
            images = draft.0; remotePaths = draft.1; uploading = draft.2
            if let error { uploadError = error }
        } else { imageDrafts[upload.key] = draft }
    }

    func removeImage(at i: Int) {
        guard images.indices.contains(i) else { return }
        let local = images[i]
        let cancelled = uploads.filter { $0.value.key == draftKey && $0.value.path == local }.map(\.key)
        for id in cancelled { uploads.removeValue(forKey: id); uploadTargets.removeValue(forKey: id) }
        uploading = max(0, uploading - cancelled.count)
        images.remove(at: i)
        if i < remotePaths.count { remotePaths.remove(at: i) }
    }
}


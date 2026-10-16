import Foundation
import Combine

/// 当前会话的内容与回合状态。
///
/// 流式 delta 每秒上百条，全部直接改 `items` 会让列表每帧重排。
/// 这里先攒进缓冲区，按 55ms 合并一次 —— 每秒最多重绘约 18 次。
@MainActor
final class ConversationModel: ObservableObject {

    /// 全局单调计数器，给 `gen` 发号。
    static let genLock = NSLock()
    static var genSeq = 0
    static func nextGen() -> Int {
        genLock.lock(); defer { genLock.unlock() }
        genSeq += 1
        return genSeq
    }

    /// 一页拉多少回合。
    static let pageSize = 40

    /// 磁盘缓存里存几个回合。
    ///
    /// 缓存走 `itemsView: full`（要保住过程条目），而 full 比 summary
    /// 大 4~28 倍（实测最坏 322KB → 1.3MB）。整个 40 轮会到几 MB，
    /// 冷启动解析也会卡。只存最近几轮，更早的靠联网补。
    static let cacheTurns = 6

    /// 缓存超过这个时长就重拉一次。
    ///
    /// 太短会把 app-server 打满（它拉一个大会话要 11~18 秒，见 prefetch
    /// 上面的注释）；太长用户就会看到过期内容。预取是串行、一次一个，
    /// 所以这个值可以小一点。
    static let cacheFreshFor: TimeInterval = 10 * 60
    /// 首屏拉多少。`thread/turns/list` 一次把 40 个回合的**完整内容**吐回来，
    /// 大会话能有几 MB —— 这是"打开会话转半天"的主因。先铺 12 个够看了。
    static let firstPage = 12

    /// 内容代数：`items` 每变一次就 +1。
    ///
    /// 派生缓存的失效键。以前是拿「条数 + 各条 id + 各条文本长度」现算指纹，
    /// 实测在 -Onone 下 `Hasher` 每 combine 一次约 0.13ms，334 条就是 **231ms**
    /// —— 比它想省掉的 `Grouping.rows`（8.2ms）贵 28 倍。
    /// 代数 +1 是 O(1)，而且不可能漏（写点全在下面 `didSet` 里）。
    ///
    /// 注意：`tick` 不能拿来干这个。它只在"有 delta 到达"时才 +1，
    /// 而 `flush()` 从空缓冲直接 return（不 +1），所以 `buf` 攒着没刷的内容
    /// 在 `tick` 上是看不见的。
    ///
    /// **必须是全局单调的，不能是实例自增的。**
    ///
    /// `Grouping.rows` 的缓存是模块级单格，键就是这个值。实例各自从 0 开始
    /// 的话，第二个 `ConversationModel` 的 `gen=1` 会撞上第一个实例 `gen=1` 留下的
    /// 缓存 —— 拿别人的渲染结果当自己的（内容串了）。
    /// 单元测试就是踩在这上面红的：每个用例都 new 一个 `AppCoordinator`，
    /// 于是"新内容和旧缓存代数相同"成了常态。
    var gen = ConversationModel.nextGen()
    @Published var items: [Item] = [] {
        didSet {
            gen = Self.nextGen()
        }
    }
    @Published var approvals: [Approval] = []
    @Published var userInputs: [ServerQuestionRequest] = []
    @Published var queued: [Queued] = []
    /// 每条"本地乐观插入"的用户消息现在处于什么状态。
    ///
    /// 以前只有 `failed` 一个布尔集合 —— 于是"发出去到被服务端接受"这段
    /// 时间是**没有任何状态**的，界面只能靠一句全局 banner 硬说
    /// "电脑端正在用这个会话，消息已排队"，把 0.2 秒的事说得很重。
    @Published var sendStates: [String: SendState] = [:]
    @Published var busy = false
    @Published var configurationPreparing = false
    @Published var loading = false
    @Published var hasOlder = false
    /// 当前已加载多少回合。往上翻会加一页。
    @Published var loadedTurns = ConversationModel.firstPage
    @Published var loadingOlder = false
    var historyRequestSeq = 0
    /// 正在把会话从磁盘读进内存。长会话要十几秒（实测 120MB 的会话
    /// `thread/resume` 花 13.6s），这期间发消息容易失败。
    @Published var resuming = false
    /// 每次打开会话 +1，视图用它触发"归位到底部"。
    @Published var openSeq = 0
    /// 每次**自己**发一条消息 +1，视图用它触发"归位到底部"。
    ///
    /// 跟 `openSeq` 分开：打开会话要归位，自己发消息也要归位，但
    /// 电脑端往会话里写消息时**不能**把正在读历史的用户拽到底部。
    @Published var sendSeq = 0
    /// 流式 tick：内容原地变长（条数不变）时计数。
    ///
    /// **不是 `@Published`。** 它现在只被常驻探针读（`tk=`），界面一个地方都
    /// 不用 —— 补滚走的是 `ScrollSensor` 对 `contentSize` 的 KVO，跟它无关。
    /// 以前它是 `@Published`，于是每次 `flush()` 都会**多推一次**全局变更：
    /// `items` 已经推过一次，`tick` 再推一次，两次都让根视图 + 抽屉 +
    /// 输入框 + 状态条整体重算。流式时 55ms 一轮，这笔账是白烧的。
    var tick = 0
    /// 这个会话烧了多少 token（服务端每轮推 thread/tokenUsage/updated）。
    @Published var usage: TokenUsage?
    /// 缓存命中用了多久 / 网络回包用了多久（毫秒，-1 = 还没发生）。
    ///
    /// 让界面能说清"慢在哪"：`warmMs` 大 = 读磁盘慢（大会话缓存几 MB），
    /// `netMs` 大 = 服务端慢。用户报「打开特别慢」时不用猜。
    @Published var warmMs = -1
    @Published var netMs = -1
    @Published var banner: String?
    /// 哪些会话正被**电脑端**占着写者锁（`thread-store conflict`）。
    ///
    /// 实测：桌面 app-server 进程持有 flock，手机端 app-server 无法
    /// `thread/resume`，`turn/start` 必然失败。占锁不代表正在运行回合，
    /// 此时不能直接排队并承诺电脑端会执行。
    ///
    /// 按会话存：切走再回来还在。以前是单个布尔 + `open()` 清零，
    /// 于是切回来忘了锁，又拿 `turn/start` 去撞一次写者锁。
    var desktopLockedThreads: Set<String> = []

    /// 当前会话是不是被电脑端占着。
    var desktopLocked: Bool {
        get { list.currentID.map { desktopLockedThreads.contains($0) } ?? false }
        set {
            guard let id = list.currentID else { return }
            let changed = newValue
                ? desktopLockedThreads.insert(id).inserted
                : desktopLockedThreads.remove(id) != nil
            // 计算属性不再有 `@Published` 的自动推送，界面靠这一下发刷新。
            if changed { objectWillChange.send() }
        }
    }
    /// 正在查看的图片（全屏）。
    @Published var previewImage: String?
    /// **回合归属按会话存，不跟着"当前打开哪个会话"走。**
    ///
    /// 用户报的 bug：「一直在一个会话里插话能用，我一切出去插话就变成排队了」。
    /// `open()` 会清 `serverTurnId` / `localTurn`，而这两样是会话的属性：
    /// 清了之后 `turn/steer` 没有 `expectedTurnId`（必填，服务端实测报
    /// "missing field `expectedTurnId`"），只能降级成排队；更糟的是
    /// `localTurn` 变 false 后轮询把**手机自己**的回合误判成电脑端占着。
    var activeTurnIds: [String: String] = [:]
    /// 哪些会话当前那个回合是**本机发起**的。
    var ownedTurnThreads: Set<String> = []

    /// 本地回合（本机发起的），用来区分电脑端发起的回合。
    var localTurn: Bool {
        get { list.currentID.map { ownedTurnThreads.contains($0) } ?? false }
        set {
            guard let id = list.currentID else { return }
            if newValue { ownedTurnThreads.insert(id) } else { ownedTurnThreads.remove(id) }
        }
    }
    /// 最近一次发送为什么走了排队/失败分支。只给探针读（排查"消息卡住"）。
    var lastSendWhy = "-"

    /// 没发出去的消息 id：渲染成红色 + 重试按钮。
    @Published var failed: Set<String> = []
    /// 发送结果未知的本地消息（回包丢了）。等一次服务端状态来判定它到底
    /// 有没有送达 —— 断线时 turn/start 的回包会丢，但消息往往已经执行。
    var pendingSend: (id: String, text: String)?
    var submissionChecks = Set<String>()

    let repository: ConversationRepositoryProtocol
    let settings: PreferencesModel
    let list: ThreadListModel

    var buf: [String: String] = [:]
    var flushTimer: Timer?
    var liveAgent: String?
    var liveReason: String?
    var liveCmd: String?
    var turnStarted: Date?
    var lastTurnId: String?
    var displayedThreadID: String?
    let suspendedTranscripts = NSCache<NSString, SuspendedTranscript>()
    var streamIsContinuous = false
    var streamEpoch = 0
    /// 服务端给的**当前活动回合** id。`turn/interrupt` 只认它。
    ///
    /// 按会话存（见 `activeTurnIds`）：切出去再回来还在，
    /// 插话不用等下一次轮询才拿到 id。
    var serverTurnId: String? {
        get { list.currentID.flatMap { activeTurnIds[$0] } }
        set {
            guard let id = list.currentID else { return }
            activeTurnIds[id] = newValue
        }
    }
    var stopRequested = false
    /// 按提交记住发送准备期间的停止请求，切会话也不能让旧请求继续发出。
    var cancelledSubmissionIDs = Set<String>()
    var sendingID: String?
    var onSubmissionResolved: ((String, Bool) -> Void)?
    var onSubmissionStarted: ((String) -> Void)?
    var onPoll: (() -> Void)?
    var activeSubmissionIDs = Set<String>()
    var uncertainSubmissionIDs = Set<String>()
    var acceptedSubmissionIDs = Set<String>()
    var completedTurnIDs = Set<String>()
    var remoteTimer: Timer?
    var remotePollingAllowed = true
    var remoteWatchGeneration = 0
    var remotePollInFlight = false
    var prefetchGeneration = 0
    var cacheRefreshInFlight = Set<String>()
    /// 当前是不是快轮询（有回合在跑）。见 `setPollFast`。
    var remotePollFast = false
    /// 轮询计数：每 3 次做一次 full 拉取（看实时思考/命令），其余用 summary 省流量。
    var remoteTick = 0
    /// 正在流式增长的"计划"条目 id。
    var livePlan: String?
    /// 上次写磁盘缓存的时间，用来节流。
    /// 每个会话上次写缓存的时间（按会话记，不是全局 ——
    /// 全局的话连开两个会话，第二个就被节流跳过了）。
    var lastCacheAt: [String: Date] = [:]
    /// 电脑端那边最新一回合的指纹，没变就不拉全量。
    var lastRemoteSig = ""
    /// 最近一次因为"轮询看到回合结束"发过通知的回合 id（防重复）。
    var lastNotifiedTurn = ""
    /// 这个会话的"已见过的最新回合"有没有记下来（见 startRemoteWatch）。
    var remotePrimed = false
    /// `remotePrimed` 是给哪个会话记的（见 startRemoteWatch）。
    var remotePrimedThread: String?
    /// 诊断：轮询被重新武装了几次 / 收到几条 status 事件（只给测试读）。
    var remoteArms = 0
    var remoteStatusEvents = 0
    var remoteStatusActive = 0
    /// 诊断：轮询跑了几次 / 其中几次看到"在跑"（只给测试读）。
    var remotePolls = 0
    var remoteActive = 0
    /// 诊断：最近一次轮询失败的原因（只给测试读）。
    var remoteErr = ""
    /// 诊断：最近一次轮询看到的回合状态原文（只给测试读）。
    var remoteStatus = ""
    /// 后台预取队列（空 = 没在跑）。
    var prefetchRunning: [String]?
    /// 轮询当前盯着的会话 id（诊断/测试用）。
    var remoteWatching: String?

    struct Queued: Identifiable {
        let id: String
        let text: String
        var clientID: String? = nil
    }

    init(repository: ConversationRepositoryProtocol, settings: PreferencesModel, list: ThreadListModel) {
        self.repository = repository
        self.settings = settings
        self.list = list
        suspendedTranscripts.countLimit = 8
    }

    var current: Thread? { list.thread(list.currentID ?? "") }

    /// 最后一条助手消息，通知里用。
    /// 把"最新一个回合"的内容并进列表尾部。
    ///
    /// 电脑端发起的回合只轮询最新一个回合（轻），这里负责把它贴到尾部：
    /// 已经在列表里的条目就地更新，新的追加 —— 不动前面的历史，
    /// 免得整列表重排（原来每次全量替换，长会话会顿一下）。
    func mergeTail(_ tail: [Item]) {
        guard !tail.isEmpty else { return }
        flush()
        for item in tail {
            guard case .user = item else { continue }
            if sendStates[item.id] != nil || pendingSend?.id == item.id {
                accept(item.id)
                if pendingSend?.id == item.id { pendingSend = nil }
            }
        }
        // 连续事件流由本地维护；导航/断线后没有连续流时，必须允许 full 恢复。
        if busy && localTurn && streamIsContinuous { return }
        var merged = items
        // **按锚点插，不是一律追加。**
        //
        // `tail` 是时间正序的（`Protocol_.items(fromTurns:)` 已把 desc 反转过
        // 来）。本地这份的覆盖范围跟服务端不一定一样：缓存只存最近
        // `cacheTurns` 轮，`reload` 一次拉 `firstPage` 轮 —— 服务端会多给几轮
        // **更旧的**。
        //
        // 以前这些没见过的条目一律 append 到末尾。末尾是"最新"那一端，
        // 于是更旧的回合被摆到了最新消息**下面**，界面又钉在底部 ——
        // 用户一进会话看到的就是旧聊天记录（实测：本地 6 轮 + 服务端 12 轮，
        // 合并后尾部多出 6 轮更旧的，探针 `…UATUATUATUATU`）。
        //
        // 规则：服务端序列里，一条没见过的条目属于"它后面那条已知条目"
        // 之前。**从后往前**处理，锚点就是那条已知条目的下标；插入时锚点
        // 不动，于是更早（更旧）的条目自动排到前面。
        var known = Set(merged.map { $0.id })
        var anchor = merged.firstIndex {
            sendStates[$0.id] != nil || pendingSend?.id == $0.id
        } ?? merged.count
        var k = tail.count - 1
        while k >= 0 {
            var it = tail[k]
            if known.contains(it.id) {
                if let i = merged.firstIndex(where: { $0.id == it.id }) {
                    if case .agent(_, let text) = it,
                       case .agent(_, let current) = merged[i], current.count > text.count {
                        it = merged[i]
                    }
                    if case .reasoning(_, let text) = it,
                       case .reasoning(_, let current) = merged[i], current.count > text.count {
                        it = merged[i]
                    }
                    if case .command(_, _, let output) = it,
                       case .command(_, _, let current) = merged[i], current.count > output.count {
                        it = merged[i]
                    }
                    if merged[i] != it { merged[i] = it }
                    anchor = i
                }
            } else {
                let p = min(anchor, merged.count)
                merged.insert(it, at: p)
                known.insert(it.id)
                anchor = p
            }
            k -= 1
        }
        if items != merged { items = merged }
        tick += 1
    }

    /// 通知兜底：本地没有助手文本时，直接问服务端要最新一个回合的。
    ///
    /// 电脑端发起的回合，手机端收不到 `item/*` delta（app-server 只发给
    /// 发起该回合的连接），所以 `items` 里根本没有助手那条 —— 通知就变成
    /// 只有标题、没有内容（用户："40 条已完成 · Xm 没内容"）。
    /// 这里按需拉一次 full 视图，把内容补上。
    func fetchLastAgentText(_ id: String, _ done: @escaping (String) -> Void) {
        repository.perform(.turns(["threadId": id, "limit": 1,
                                      "sortDirection": "desc",
                                      "itemsView": "full"])) { r in
            guard case .success(let v) = r,
                  let turn = (v as? JSONDict)?.dicts("data").first else { done(""); return }
            parseConversationItemsOffMain(["data": [turn]]) { items in
                let text = items
                    .filter { $0.isAgent }
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                done(text)
            }
        }
    }

    func lastAgentText() -> String {
        for it in items.reversed() where it.isAgent {
            let t = it.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return ""
    }


}

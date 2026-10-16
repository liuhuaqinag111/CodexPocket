import Foundation
import Combine

/// 会话列表：分组、搜索、归档、重命名、新建。
///
/// 只碰列表相关状态，不碰当前会话内容（那是 ConversationModel）。
@MainActor
final class ThreadListModel: ObservableObject {

    struct Group: Identifiable {
        let id: String
        let title: String
        let path: String
        let threads: [Thread]
        let isProject: Bool
        var isArchive = false
        var isEmptyProject = false
        /// 服务端全文搜索的结果分组。
        var isSearch = false
    }

    @Published var threads: [Thread] = []
    @Published var archived: [Thread] = []
    @Published var projects: [Project] = []
    @Published var models: [ModelOption] = []

    /// 电脑端 `~/.codex/config.toml` 里的全局模型与推理强度。
    ///
    /// App 以前**从不**读它 —— 会话自己没记模型时界面就是空的或"默认模型"，
    /// 看着就像"手机和电脑端不一致"。连上和前台轮询时只读同步。
    @Published var globalModel = ""
    @Published var globalEffort = ""
    /// 电脑端允许的强度档位（`config.desktop.enabled-reasoning-efforts`）。
    /// 全局模型不在 `model/list` 目录里时，用它把强度选择撑起来。
    @Published var globalEfforts: [String] = []
    var configurationRead: (id: String?, at: Date)?
    var configurationInFlight: (id: String?, sequence: Int)?
    var configurationCallbacks: [Int: [() -> Void]] = [:]
    var confirmedConfigurationID: String?
    var configurationReadSeq = 0
    var configurationChanges = 0
    var configurationWrites: [String: Int] = [:]
    @Published var loading = false
    /// 至少成功拉到过一次列表。用来区分"还没拉"和"拉回来是空的" ——
    /// 后者要报出来（见 ThreadListView.emptyState）。
    @Published var fetchedOnce = false
    /// 列表拉完的回调（AppCoordinator 用它触发预取）。
    var onLoaded: (([String]) -> Void)?
    /// 新会话创建成功后的首条消息交给当前会话发送器，不能直接在列表层发 turn/start。
    var onFirstMessage: ((String, String) -> Void)?
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    /// 服务端全文搜索的结果（`thread/search`）。
    ///
    /// 本地只按标题过滤 —— 搜"竞彩"搜不到正文里写过竞彩的会话。
    /// 服务端能搜正文（实测搜"竞彩"返回 17 条），这里接上。
    @Published var searchHits: [Thread] = []
    /// 命中片段（原文那一段），显示在行下面。
    @Published var searchSnippets: [String: String] = [:]
    /// 服务端搜索请求的序号：回包乱序时只认最后一次。
    var searchSeq = 0
    var searchTimer: Timer?
    /// 跟服务端对账的定时器（见 reconcileInterval 的注释）。
    var reconcileTimer: Timer?
    /// 列表页当前是不是开着（切后台要停、回前台要接回来）。
    var reconcileWanted = false
    /// 对账定时器在不在跑。只给回归测试读（切后台必须停）。
    var isReconciling: Bool { reconcileTimer != nil }
    var reconcileMisses = 0
    var reconcilePass = 0
    var activeListReadSeq = 0
    var archivedListReadSeq = 0
    var activeFullReadSeq: Int?
    var archivedFullReadSeq: Int?
    var projectReadSeq = 0
    var modelReadSeq = 0
    var modelCatalogRead: (connection: Int, at: Date)?
    var modelProviderFingerprint: String?
    @Published var modelCatalogError: String?
    /// 连接目标变更时递增。旧服务器的 mutation 回包不能回写到新服务器。
    var connectionGeneration = 0
    /// 诊断：这一轮各翻了几页（只给测试读）。
    var activePages = 0
    var archivedPages = 0
    /// 诊断：`fetchAllPages` 里每页回来的行数（只给测试读）。
    var lastPageSizes: [String] = []
    /// 当前打开的会话，用来把它所在的项目置顶。
    @Published var currentID: String?
    @Published var banner: String?
    /// 刚 `thread/start` 出来、服务端 `thread/list` 还没落盘的会话。
    /// `load()` 会用服务端结果整体替换列表，不补回来的话新会话会瞬间消失 ——
    /// 表现就是"新会话创建不了"（点完铅笔，列表里找不到刚建的）。
    var pendingNew: [String: (Thread, Date)] = [:]
    /// 最近一次新建会话，服务端实际给的工作目录。
    /// 调试探针用：新建后 `thread/list` 有落盘延迟，查不到刚建的会话，
    /// 测试没法从外部确认 cwd。
    var lastCreatedCwd: String?

    let repository: ThreadRepositoryProtocol
    let settings: PreferencesModel
    let d = UserDefaults.standard
    /// 本地归属表：threadId → projectId。见 `move`。
    @Published var filed: [String: String] = [:]

    init(repository: ThreadRepositoryProtocol, settings: PreferencesModel) {
        self.repository = repository
        self.settings = settings
        filed = d.dictionary(forKey: "filedProjects") as? [String: String] ?? [:]
    }


}

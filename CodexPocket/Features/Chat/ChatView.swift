import SwiftUI

/// 会话页。
///
/// 滚动与自动跟随是这里最难的部分。规则只有两条，而且**不在 SwiftUI 里实现**：
///   1. 用户自己翻上去（手指松开时离底部还远）→ 自动跟随让路。
///   2. 其余情况内容一律钉在最新一条上 —— 由 `ScrollSensor` 直接写
///      `contentOffset` 完成，同步、精确，不用定时器、不用 ScrollViewReader。
/// 之前那套 `follow/userHold/atBottom/settle()` 状态机之所以"上下乱滑 /
/// 突然回到最上面"，是因为它靠 `scrollTo(anchor:)` 反复重试：LazyVStack 是懒的，
/// 锚点不存在时 scrollTo 静默失败，只能定时重来，永远慢半拍。
struct ChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var store: AppCoordinator
    @EnvironmentObject var chat: ConversationModel
    /// 整个 body 被重算的次数。排查"滑动卡"：SwiftUI 里没有现成的计数器，
    /// 而 `sense()` 每秒会往 @State 写十几次，每次写都让 body 重算一遍。
    static var bodyRuns = 0
    /// 所有 `body` 重算加起来的毫秒数。
    static var bodyMs: Double = 0
    /// 超过一帧预算（16.7ms）的重算次数 + 最慢的一次。
    static var bodySlow = 0
    static var bodyMax: Double = 0

    /// 用户自己翻上去了（自动跟随已让路）。
    @State var showLatest = false
    @State var atBottom = true
    /// 递增它 = 请求归位到最新（打开会话 / 点「回到最新」）。
    @State var followGen = 0
    @State var holdPositionGen = 0
    /// 传感器报上来的两个原始值，只在排查滚动问题时看。
    /// 「回到最新」按钮被按下的次数。排查"第一次点没反应"用。
    @State var latestTaps = 0
    /// 只给回归测试读、界面不用的那几个量。
    ///
    /// 它们每秒变十几次。以前是四个 `@State`，每写一次就让整个
    /// `ChatView.body` 重算 —— 一次重算里有 `Grouping.rows`（实测 8.2ms ×2）、
    /// `Markdown.body`（实测 57.6ms）。
    /// 用户报的「上下滑好卡」就是这笔账。
    ///
    /// **必须是 `@State` 装的引用盒子**，两者缺一不可：
    ///   - `@State`：跨 view 重建保留。用 `let` 的话 SwiftUI 每次重建
    ///     struct 都会 new 一个新盒子，`sense()` 写进旧盒子、探针读新盒子，
    ///     读出来永远是 0（实测 `ch=0.0 vh=0.0 y=0.0`，`NoPullTests` /
    ///     `JitterTests` 因此静默跳过 —— 假绿）。
    ///   - 引用类型：改盒子内部字段不经过 `@State` 的 setter，
    ///     不会触发重绘。这正是把它从 `@State CGFloat` 换过来的原因。
    @State var probe = ProbeBox()

    @State var showSettings = false
    @State var showConfig = false
    @State var showUsage = false
    @State var help = false
    @State var showWorkspace = false

    var list: ThreadListModel { store.list }

    var body: some View {
        let t0 = CFAbsoluteTimeGetCurrent()
        let v = content
        // 量一次 `body` 重算要多少毫秒。滑动时每秒重算十几次，
        // 单次成本直接决定跟不跟手 —— 光看"重算了几次"不够。
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        Self.bodyMs += ms
        Self.bodyRuns += 1
        // 掉帧的判据：单次重算超过一帧预算（16.7ms）就是卡的那一下。
        if ms > 16.7 { Self.bodySlow += 1 }
        if ms > Self.bodyMax { Self.bodyMax = ms }
        return v
    }

    var content: some View {
        ZStack(alignment: .top) {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶栏必须占正常布局高度；透明只影响视觉，不应让消息进入它的裁剪区。
                header
                StatusStrip()
                // 断线/重连时才有的一条状态带（正常时不占高度）。
                messages
                // 输入框周围**全透明**：不加任何渐变 / 底色，
                // 内容直接滚到输入条底下（用户："输入框周围全是透明的"）。
                Composer()
            }
            chatState
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showConfig) { ThreadConfigSheet() }
        .sheet(isPresented: $showUsage) { UsageSheet() }
        .sheet(isPresented: $showWorkspace) { WorkspaceView() }
        .alert("可用命令", isPresented: $help) {
            Button("好", role: .cancel) { }
        } message: {
            Text(Suggestions.commands.map { "/\($0.insert)  —  \($0.title)" }
                .joined(separator: "\n"))
        }
        // `/model`、`/usage`、`/help` 需要界面配合，走出到视图这一层。
        .onAppear { store.composer.onCommand = { cmd in
            switch cmd {
            case "model": showConfig = true
            case "usage": showUsage = true
            case "help": help = true
            default: break
            }
        } }
        // 打开会话 = 归位到最新。不依赖 ScrollViewReader，也不需要重试。
        .onChange(of: chat.openSeq) { _ in followGen += 1 }
        // 自己发一条消息也立刻归位。
        //
        // 以前只有 `openSeq`（打开会话）这一条通道。用户翻上去看历史时发消息，
        // 新气泡在屏幕外 —— 界面**看起来**没反应，于是再点一次发送键，
        // 就成了两条。这条通道只在自己发消息时触发，不会把正在读历史的
        // 用户拽回底部（那时 `sendSeq` 不变）。
        .onChange(of: chat.sendSeq) { _ in
            showLatest = false
            followGen += 1
        }
        .onAppear { followGen += 1 }
    }
}

/// 只给回归测试读的滚动量。
///
/// 故意用 class：SwiftUI 的 `View` 是 struct，普通存储属性在 `sense()`
/// 里改不了；而 `@State` 每次写都会触发整页重算。这个盒子两样都躲开 ——
/// 引用不变，SwiftUI 看不到任何变化。
final class ProbeBox {
    var offY: CGFloat = 0
    var viewportH: CGFloat = 0
    var contentH: CGFloat = 0
    var hold = false
    var scrollKind = ""

    // 派生探针的记忆格。
    //
    // `ord=` / `raw=` / `ag=` / `tb=` 都是 `items` 的纯函数，而 `items` 的每次
    // 变化都会推进 `chat.gen`。键对上就直接返回上次的结果 —— 否则每个 body
    // 都要把 260 多条全 map 一遍（实测单次 3~8ms，`ChatView.body` 平均 8ms
    // 里有大半是这笔账）。值永远是准的，只是不重复算。
    var probeGen = Int.min
    var probeTick = Int.min
    var probeBusy = false
    var probeTurn: String?
    var ord = ""
    var raw = ""
    var ag = 0
    var tb = ""
}

// MARK: - 测试探针

extension ChatView {
    /// 常驻的无障碍元素，把滚动状态机的内部量暴露成文本。
    ///
    /// 回归测试（"底部乱跳"这类）只能靠这些数字判定：读常驻元素的
    /// `accessibilityValue` 比截图比对稳，也比猜手势结果准。
    /// 格式：`y=底部Y vh=视口高 f=跟随 hold=按着 ch=内容高 off=偏移`
    var chatState: some View {
        // nc = 最近一次新建会话的 cwd（服务端回的真值）。
        Text("")
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityElement()
            .accessibilityIdentifier("chatState")
            .accessibilityValue("y=\(Int(probe.offY)) vh=\(Int(probe.viewportH)) "
                                + "latest=\(showLatest ? 1 : 0) "
                                + "hold=\(probe.hold ? 1 : 0) lt=\(latestTaps) fg=\(followGen) sa=\(atBottom ? 0 : 1) ch=\(Int(probe.contentH)) "
                                + "bot=\(atBottom ? 1 : 0) n=\(chat.items.count) "
                                + "br=\(Self.bodyRuns) bms=\(Int(Self.bodyMs)) "
                                + "bslow=\(Self.bodySlow) bmax=\(Int(Self.bodyMax)) "
                                + "req=\(WebSocketTransport.outbound.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")) "
                                + "rp=\(chat.remotePolls) ra=\(chat.remoteActive) re=\(chat.remoteErr.prefix(20)) rs=\(chat.remoteStatus) "
                                + "busy=\(chat.busy ? 1 : 0) tk=\(chat.tick) "
                                + "buf=\(chat.buf.count) st=\(store.state.label) "
                                + "last=\(chat.items.last?.id.prefix(6) ?? "-")"
                                + "/\(chat.items.last?.text.count ?? 0) "
                                + "cid=\(chat.current?.id.prefix(6) ?? "-") "
                                + "cwd=\(chat.current?.cwd ?? "-") "
                                + "nc=\(list.lastCreatedCwd ?? "-") "
                                + "ag=\(derivedProbes().ag) "
                                + "ord=\(derivedProbes().ord) "
                                + "raw=\(derivedProbes().raw) "
                                + "tb=\(derivedProbes().tb) "
                                + "fz=\(Int(FreezeWatchdog.maxStallMs)) "
                                + "fs=\(FreezeWatchdog.stallCount) "
                                + "fst=\(FreezeWatchdog.stage) "
                                + "rb=\(RootView.bodyRuns) rms=\(Int(RootView.bodyMs)) "
                                + "rmax=\(Int(RootView.bodyMax)) "
                                + "cp=\(chat.configurationPreparing ? 1 : 0) "
                                + "warm=\(chat.warmMs) net=\(chat.netMs) "
                                + "sw=\(chat.lastSendWhy.prefix(40))")
    }
}

extension ChatView {
    /// 派生探针（`ag` / `ord` / `raw` / `tb`）的记忆化入口。
    ///
    /// 这四个都是 `chat.items` 的纯函数，键 = 内容代数 + tick + 进行中的回合 id。
    /// 键没变就直接返回上次的结果，键变了才重算 —— 值永远是最新的，
    /// 但同一份内容不会被 body 重算反复扫。
    func derivedProbes() -> (ord: String, raw: String, ag: Int, tb: String) {
        let g = chat.gen, t = chat.tick
        let b = chat.busy, turn = chat.busy ? chat.lastTurnId : nil
        let box = probe
        if box.probeGen == g, box.probeTick == t, box.probeBusy == b,
           box.probeTurn == turn {
            return (box.ord, box.raw, box.ag, box.tb)
        }
        box.probeGen = g
        box.probeTick = t
        box.probeBusy = b
        box.probeTurn = turn
        box.ord = orderProbe
        box.raw = rawProbe
        box.ag = chat.items.reduce(0) { $0 + ($1.isAgent ? $1.text.count : 0) }
        box.tb = tbProbe
        return (box.ord, box.raw, box.ag, box.tb)
    }

    /// 渲染顺序（`Grouping` 排完之后）的字母串，只给测试读。
    ///
    /// 用户报过「回复下面还有思考」。`Grouping` 的单测显示排序是对的，
    /// 所以要看**渲染这一层**实际拿到什么顺序：
    /// U 用户 / R 思考 / A 正文 / C 命令 / F 改动 / P 计划 / T 分隔线 / W(...) 折叠组。
    var orderProbe: String {
        Grouping.rows(chat.items, liveTurnId: chat.busy ? chat.lastTurnId : nil,
                                  gen: chat.gen)
            .map { r -> String in
                switch r {
                case .one(let it): return Self.letter(it)
                case .work(_, let members, _, _):
                    return "W(" + members.map { Self.letter($0) }.joined() + ")"
                }
            }
            .joined()
    }

    /// 原始 items 数组的顺序（未经 Grouping 重排）。
    var rawProbe: String { chat.items.map { Self.letter($0) }.joined() }

    /// 每个分隔线的 id 后缀 + 时长（-1 = 还没定）。
    var tbProbe: String {
        chat.items.compactMap { it -> String? in
            guard case .turnBreak(let i, _, let d) = it else { return nil }
            return i.suffix(6) + ":" + String(Int(d ?? -1))
        }.joined(separator: ",")
    }

    static func letter(_ it: Item) -> String { Grouping.letter(it) }
}

// MARK: - 消息列表

extension ChatView {
    var messages: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    // 更早的消息。以前这里什么都没有 —— `hasOlder`
                    // 只被赋值没人读，长会话翻不上去。
                    if chat.hasOlder {
                        Button {
                            holdPositionGen += 1
                            chat.loadOlder()
                        } label: {
                            HStack(spacing: 6) {
                                if chat.loadingOlder {
                                    ProgressView().controlSize(.small)
                                } else {
                                    LucideIcon("arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text(chat.loadingOlder ? "加载中…" : "加载更早的消息")
                                    .font(Palette.F.note)
                            }
                            .foregroundStyle(Palette.textSub)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(chat.loadingOlder)
                        .accessibilityIdentifier("chat.loadOlder")
                    }

                    // 按回合分组：进行中的回合全平铺，结束的回合把
                    // 中间过程（思考/命令/工具/改文件/计划）收成一行。
                    // 以前十几行过程把回复挤到屏幕外（用户截图里就是）。
                    ForEach(Grouping.rows(chat.items,
                                          liveTurnId: chat.busy ? chat.lastTurnId : nil,
                                          gen: chat.gen)) { row in
                        switch row {
                        case .one(let item):
                            MessageRow(item: item,
                                       live: chat.busy && item.id == chat.items.last?.id,
                                       failed: chat.failed.contains(item.id),
                                       sendState: chat.sendStates[item.id],
                                       onResend: { resend(item) },
                                       onRegenerate: { regenerate(item) })
                                .equatable()
                                .environment(\.quoteSelection, { store.composer.appendQuote($0) })
                                .id(item.id)
                        case .work(_, let members, _, let dur):
                            WorkGroup(items: members, summary: row.summary, duration: dur)
                                .id(row.id)
                        }
                    }

                    ForEach(chat.approvals) { req in
                        ApprovalRow(request: req)
                    }
                    ForEach(chat.userInputs) { request in
                        UserInputRequestView(request: request)
                    }

                    if chat.queued.count > 0 { QueueRow() }

                    if chat.busy && !chat.items.contains(where: { $0.isAgent && $0.text.isEmpty }) {
                        TypingDots().padding(.top, 2)
                    }

                    if chat.resuming && !chat.items.isEmpty {
                        Text("正在打开会话…")
                            .font(Palette.F.caption)
                            .foregroundStyle(Palette.textFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }

                    if chat.loading && chat.items.isEmpty {
                        HStack { Spacer(); ProgressView().tint(Palette.textFaint); Spacer() }
                            .padding(.top, 60)

                    }
                }
                .padding(.horizontal, UI.gutter)
                .padding(.top, 24)
                .padding(.bottom, 16)
                .environment(\.holdChatPosition, { holdPositionGen += 1 })
                .background(ScrollSensor(onScroll: { m in sense(m) }, followGen: followGen,
                                         holdGen: holdPositionGen))
            }
            .coordinateSpace(name: "chatScroll")
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("chat.messages")
            .overlay {
                if chat.items.isEmpty && !chat.loading && !chat.resuming {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("CODEX POCKET").font(Palette.F.caption.weight(.semibold))
                            .tracking(2).foregroundStyle(Palette.accentText)
                        Text("从这里，\n开始下一步。")
                            .font(Palette.F.hero).foregroundStyle(Palette.text)
                            .accessibilityIdentifier("chat.empty")
                        Text("写下任务，或添加一张图片。")
                            .font(Palette.F.body).foregroundStyle(Palette.textSub)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, UI.gutter).padding(.top, 40)
                    .allowsHitTesting(false)
                }
            }

        }
        // 放在消息容器的覆盖层，始终位于输入框上方；独立覆盖层接收点击。
        .overlay(alignment: .bottomTrailing) {
            if showLatest && !chat.items.isEmpty { latestButton.zIndex(1) }
        }
    }

    /// 滚动视图报上来的状态。
    ///
    /// 自动钉底**不在这里做** —— 那是 ScrollSensor 内部的事（同步、精确）。
    /// 这里只把状态搬进 @State，供探针和「回到最新」按钮使用。
    func sense(_ m: ScrollSensor.Metrics) {
        guard m.viewport > 200, m.content > 200 else { return }
        // 只在真的变了才写 @State：KVO 是在布局过程中回调的，
        // 每次都赋值会"改状态 → 重排 → 再回调"转成死循环，
        // 主线程被占满，系统会以看门狗把 App 杀掉（实测崩溃）。
        // **探针用的那几个值不再进 @State。**
        //
        // `gap / viewport / content / kind` 只有常驻探针在显示，界面本身
        // 一个都不用。而它们每秒变十几次，每写一次就让 `ChatView.body`
        // 整体重算 —— 一次重算里有 `Grouping.rows`（实测 8.2ms ×2）、
        // `Markdown.body`（实测 57.6ms）。
        // 用户报的「上下滑好卡」就是这笔账。改成普通存储属性，探针照读，
        // 但不触发重绘。
        probe.offY = m.gap
        probe.viewportH = m.viewport
        probe.contentH = m.content
        if probe.scrollKind.isEmpty { probe.scrollKind = m.kind }
        probe.hold = m.hold
        // 只有这几个真的影响界面（「回到最新」按钮显不显示），
        // 它们的变化频率是"翻上去一次"，不是每帧。
        if atBottom != m.atEnd { atBottom = m.atEnd }
        if showLatest != m.away { showLatest = m.away }
    }

    /// 「回到最新」。只在用户主动翻上去之后出现。
    /// 只看 atBottom 不行：内容比视口高的时候它本来就是 false，
    /// 一进会话就挂个按钮在那儿（ChatGPT 没有）。
    var latestButton: some View {
        Button {
            latestTaps += 1
            followGen += 1
            showLatest = false
        } label: {
            LucideIcon("arrow.down")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 36, height: 36)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: 12))
                // 视觉保持 36，命中区扩到 48。
                // 这个按钮装在页面 overlay 上，命中区默认按可见形状算；
                // 只给 36 的话，点偏一点就落在按钮外被 ScrollView 吃掉
                // —— 用户报的「下拉按钮不生效」就是这个（实测：要点第二次）。
                .padding(6)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .padding(.trailing, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("回到最新消息")
        .accessibilityIdentifier("chat.latest")
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
    }

    /// 重新生成：找到这条助手回复之前最近的用户消息，重发一遍。
    func regenerate(_ item: Item) {
        guard let i = chat.items.firstIndex(where: { $0.id == item.id }) else { return }
        for j in stride(from: i - 1, through: 0, by: -1) {
            if case .user(_, let text, _) = chat.items[j], !text.isEmpty {
                store.chat.send(text)
                return
            }
        }
    }

    func resend(_ item: Item) {
        guard case .user(let id, let text, let images) = item else { return }
        // 传 id：重试要复用这条气泡，不能再新增一条。
        // 图片一起带上 —— 只发文字的话重试出来的消息会丢图。
        store.composer.retry(id, text: text, images: images)
    }
}

// MARK: - 顶栏 / 审批 / 队列

extension ChatView {
    /// 标题保持透明，只让操作按钮浮在内容上方。
    var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CircleButton(system: "panel-left", identifier: "chat.menu") {
                    store.showDrawer = true
                }
                .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("打开会话列表")
                Button { showConfig = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chat.current?.displayTitle ?? "新会话")
                            .font(Palette.F.title).foregroundStyle(Palette.text)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text("会话设置").font(Palette.F.caption)
                            LucideIcon("chevron-down", size: 12)
                        }
                        .foregroundStyle(Palette.textSub)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.title")
                ConnectionIndicator()
                Menu {
                    Button { store.composer.newThread() } label: { LucideLabel("新会话", "square-pen") }
                        .accessibilityIdentifier("chat.new")
                    Button { showConfig = true } label: { LucideLabel("会话设置", "sliders-horizontal") }
                        .accessibilityIdentifier("chat.config")
                    Button { showWorkspace = true } label: { LucideLabel("工作区", "panels-top-left") }
                    Button { store.chat.catchUp() } label: { LucideLabel("刷新", "refresh-cw") }
                        .accessibilityIdentifier("chat.catchup")
                } label: {
                    LucideIcon("ellipsis").foregroundStyle(Palette.text)
                        .frame(width: 44, height: 44)
                }
                .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("更多操作").accessibilityIdentifier("chat.more")
            }
            .padding(.horizontal, UI.gutter).padding(.vertical, 8)
            HStack(spacing: 12) {
                Text(chat.busy ? "正在处理" : "对话")
                    .font(Palette.F.caption.weight(.semibold))
                    .foregroundStyle(chat.busy ? Palette.accentText : Palette.textSub)
                Spacer()
                Button { showWorkspace = true } label: {
                    HStack(spacing: 6) {
                        LucideIcon("panels-top-left", size: 16)
                        Text("工作区").font(Palette.F.caption.weight(.medium))
                    }
                    .foregroundStyle(Palette.accentText).frame(minHeight: 44)
                }
                .buttonStyle(.plain).accessibilityIdentifier("chat.workspace")
            }
            .padding(.horizontal, UI.gutter)
            Hairline()
        }
        .background(Palette.bg)
    }

}

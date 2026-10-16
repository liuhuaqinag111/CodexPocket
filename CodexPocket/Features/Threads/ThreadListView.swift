import SwiftUI

/// 原生列表保留滑动操作，工作入口与会话分区共享清晰的阅读轴线。
struct ThreadListView: View {
    @EnvironmentObject var store: AppCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showSettings = false
    @State private var showNew = false
    @State private var searching = false
    @State private var renaming: Thread?
    @State private var renameText = ""
    /// 待确认真删的会话。
    @State private var pendingDelete: Thread?
    /// 正在选项目的会话。
    @State private var moving: Thread?
    @State private var confirmDelete: Thread?
    @State private var showWorkspace = false

    private var list: ThreadListModel { store.list }

    var body: some View {
        NavigationStack {
            inner
        }
    }

    private var inner: some View {
        ZStack(alignment: .bottomTrailing) {
            Palette.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                statusLine
                if searching {
                    SearchField(text: Binding(get: { list.query }, set: { list.query = $0 }))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
                if let banner = list.banner { errorNotice(banner) }
                if list.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    navigationShortcuts
                }
                content
            }

            // zIndex 必须显式给：`content` 是 List（UIKit 支撑），
            // 不加的话它会把右下角这个胶囊的触摸吃掉 ——
            // 用户看到按钮在那儿，点下去没反应（"聊天按钮点不动"）。
            chatPill.zIndex(2)

            // 回归测试用的探针：把列表内部计数暴露成文本。
            Text("")
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityElement()
                .accessibilityIdentifier("listState")
                .accessibilityValue(probe)
        }
        // 列表页可见期间跟服务端对账：电脑端的归档/删除/新建
        // 一条事件都传不过来（通知只回发起方，见 ThreadListModel.reconcileInterval）。
        .onAppear { list.startReconcile(); list.fetchThreads(); list.fetchArchived() }
        .onDisappear { list.stopReconcile() }
        .navigationDestination(for: ListRoute.self) { route in
            switch route {
            case .projects: ProjectsView()
            case .library: LibraryView()
            case .project(let p): ProjectDetailView(project: p)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNew) { NewThreadView() }
        .sheet(isPresented: $showWorkspace) { WorkspaceView() }
        .alert("重命名会话", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("保存") {
                if let t = renaming { list.rename(t, to: renameText) }
                renaming = nil
            }
        }
        .alert("删除这个会话？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let t = pendingDelete { list.delete(t) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("会话记录会从电脑上删掉，不能恢复。只想收起来就用「归档」。")
        }
        .alert("归档这个会话？", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("取消", role: .cancel) { confirmDelete = nil }
            Button("归档", role: .destructive) {
                if let t = confirmDelete { list.archive(t, true) }
                confirmDelete = nil
            }
        } message: {
            Text("会话会移到「已归档」，不会从电脑上消失。")
        }
        // 移到项目：列出所有项目 + 「移出项目」。
        // 项目归属按 cwd 前缀算，所以这里选的是会话的工作目录。
        .confirmationDialog("把这个会话归到哪个项目？", isPresented: Binding(
            get: { moving != nil },
            set: { if !$0 { moving = nil } }
        ), titleVisibility: .visible) {
            ForEach(list.projects) { p in
                Button(p.name) {
                    if let t = moving { list.move(t, to: p) }
                    moving = nil
                }
            }
            Button("移出项目") {
                if let t = moving { list.unfile(t) }
                moving = nil
            }
            Button("取消", role: .cancel) { moving = nil }
        }
    }
}

extension ThreadListView {
    private func iconButton(_ icon: String, label: String, id: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LucideIcon(icon, size: 20)
                .foregroundStyle(Palette.text)
                .frame(width: 44, height: 44)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(Pressable())
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func errorNotice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            LucideIcon("circle-alert", size: 18).foregroundStyle(Palette.danger)
            Text(text).font(Palette.F.caption).foregroundStyle(Palette.textSub)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { list.banner = nil } label: {
                LucideIcon("x", size: 16).frame(width: 44, height: 44)
            }.accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("关闭提示")
        }
        .padding(.leading, 12).padding(.vertical, 8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20).padding(.bottom, 12)
    }
    private var navigationShortcuts: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            Button { showWorkspace = true } label: {
                shortcutLabel("layers-2", "工作区")
            }.accessibilityIdentifier("list.workspace")
            NavigationLink(value: ListRoute.projects) {
                shortcutLabel("folder", "项目")
            }.accessibilityIdentifier("list.entry.项目")
            NavigationLink(value: ListRoute.library) {
                shortcutLabel("archive", "已归档")
            }.accessibilityIdentifier("list.entry.库")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    private func shortcutLabel(_ icon: String, _ title: String) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        return layout {
            LucideIcon(icon, size: 20).foregroundStyle(Palette.accentText)
            Text(title).font(Palette.F.group).foregroundStyle(Palette.text)
        }
        .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 44 : 66, alignment: .leading)
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
    /// 大标题配轻量搜索、设置入口。
    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex")
                    .font(typeSize.isAccessibilitySize ? .title2.weight(.bold) : .largeTitle.weight(.bold))
                    .tracking(-1)
                    .foregroundStyle(Palette.text)
                    .accessibilityIdentifier("list.title")
                Text("你的随身工作台")
                    .font(typeSize.isAccessibilitySize ? Palette.F.caption : Palette.F.note)
                    .foregroundStyle(Palette.textSub)
            }

            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 8) {
            iconButton(searching ? "x" : "search", label: "搜索会话", id: "list.search") {
                withAnimation(reduceMotion ? nil : Motion.quick) {
                    searching.toggle()
                    if !searching { list.query = "" }
                }
            }
            iconButton("settings-2", label: "设置", id: "list.me") { showSettings = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    /// 没连上时的提示行，点一下立刻重连。
    @ViewBuilder
    private var statusLine: some View {
        if !store.state.isReady {
            Button { store.rpc.reconnectNow() } label: {
                HStack(spacing: 6) {
                    LucideIcon("wifi-off", size: 16)
                    Text(store.state.label + "，轻点重试")
                        .font(Palette.F.caption)
                        .foregroundStyle(Palette.textFaint)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("list.status")
        }
    }

    private var content: some View {
        List {
            // 1) 项目：一个项目一段，会话在它下面缩进一档，默认收起。
            //    必须排在无项目会话**前面** —— 否则项目被十几条无项目会话
            //    顶到屏幕外，用户根本看不到（"看不到项目里的会话"）。
            if list.query.trimmingCharacters(in: .whitespaces).isEmpty,
               !list.projects.isEmpty {
                Section {
                    ForEach(list.groups.filter { $0.isProject && !$0.isArchive }) { g in
                        GroupHeader(title: g.title, count: g.threads.count,
                                    open: list.isOpen(g), canToggle: true) {
                            withAnimation(reduceMotion ? nil : Motion.quick) { list.toggle(g) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20,
                                                  bottom: 0, trailing: 20))

                        if list.isOpen(g) {
                            if g.threads.isEmpty {
                                Text("这个项目还没有会话")
                                    .font(Palette.F.note)
                                    .foregroundStyle(Palette.textFaint)
                                    .padding(.leading, 16)
                                    .padding(.vertical, 6)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 12,
                                                              bottom: 0, trailing: 12))
                            }
                            ForEach(g.threads) { t in
                                row(t, archive: false, indent: 14)
                            }
                        }
                    }
                } header: {
                    Text("项目")
                        .font(Palette.F.group)
                        .foregroundStyle(Palette.text)
                        .textCase(nil)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                }
            }

            // 2) 最近：没有项目的会话平铺。
            Section {
                if list.threads.isEmpty && list.archived.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                let rows = list.query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? list.recent : list.allMatching
                ForEach(rows) { t in row(t, archive: false) }

                if !list.query.isEmpty && rows.isEmpty {
                    emptySearch
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                if !list.archived.isEmpty {
                    GroupHeader(title: "已归档", count: list.archived.count,
                                open: list.isOpenArchive, canToggle: true) {
                        withAnimation(reduceMotion ? nil : Motion.quick) { list.toggleArchive() }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 0, trailing: 20))

                    if list.isOpenArchive {
                        ForEach(list.archived) { t in row(t, archive: true) }
                    }
                }
            } header: {
                Text(list.query.isEmpty ? "最近会话" : "搜索结果")
                    .font(Palette.F.group)
                    .foregroundStyle(Palette.text)
                    .textCase(nil)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable { list.load() }
        .scrollDismissesKeyboard(.interactively)
        .padding(.bottom, 76)      // 给右下角新建按钮让位
    }

    /// 探针文本。单独拆出来 —— 塞在 `accessibilityValue` 里
    /// 会让 Swift 的类型检查卡死（实测 "unable to type-check in reasonable time"）。
    private var probe: String {
        let groups = list.groups.map { g -> String in
            let p = g.isProject ? "P" : "n"
            let o = list.isOpen(g) ? "o" : "c"
            return g.title + "[" + String(g.threads.count) + p + o + "]"
        }.joined(separator: ",")
        var head = "th=" + String(list.threads.count)
            + " pj=" + String(list.projects.count)
            + " gp=" + String(list.groups.count)
            + " rc=" + String(list.recent.count)
            + " ar=" + String(list.archived.count)
        head += " ap=" + String(list.activePages)
            + " arp=" + String(list.archivedPages)
            + " pgs=" + list.lastPageSizes.suffix(6).joined(separator: "/")
            // 正在运行的会话数。服务端报 status.type=active，
            // 以前只认 "running"/"inProgress"（服务端从不发），
            // 列表页的"正在运行"指示器就永远不亮。
        head += " run=" + String((list.threads + list.archived).filter { $0.running }.count)
            // 耗电诊断：列表页放着不动时每个方法发了多少次。
        head += " req=" + WebSocketTransport.outbound.map { "\($0.key):\($0.value)" }.sorted()
                .joined(separator: ",")
        return head + " " + groups
    }

    private var emptySearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            LucideIcon("search", size: 28).foregroundStyle(Palette.textSub)
            Text("没有找到匹配的会话").font(Palette.F.bodyBold)
            Text("换一个关键词，也可以搜索会话正文。")
                .font(Palette.F.note).foregroundStyle(Palette.textSub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 32)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if list.loading {
                ProgressView().tint(Palette.textFaint)
                Text("载入中…")
            } else if !store.state.isReady {
                LucideIcon("wifi-off", size: 32)
                Text("未连接到电脑")
                Text("确认电脑上 Codex 在运行，然后点上方重试")
            } else if list.fetchedOnce && list.threads.isEmpty {
                // **连上了、也拉过了，但一条都没有。**
                //
                // 这个状态以前跟"新用户还没建过会话"长得一模一样，
                // 都显示"还没有会话 / 点右下角「聊天」开始"。于是
                // 桥接上游指错端口那种故障（2026-10-06：app-server 在
                // 62115，桥接去连 62112）在手机上看起来就是"我的会话全没了"，
                // 而不是"连接有问题"。这里必须区分开。
                LucideIcon("message-circle", size: 32)
                Text("没拉到会话")
                Text("还没有返回会话，下拉重新载入，或到设置查看连接状态。")
            } else {
                LucideIcon("message-circle", size: 32)
                Text("还没有会话")
                Text("写下一个想法，从新会话开始。")
            }
        }
        .font(Palette.F.note)
        .foregroundStyle(Palette.textFaint)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func row(_ t: Thread, archive: Bool, indent: CGFloat = 0) -> some View {
        // 缩进做在内容里，不用 listRowInsets —— `.plain` 风格下它会失效，
        // 项目下的会话会跟项目平级（用户看到的"没缩进"）。
        Button { store.open(t) } label: {
            ThreadRow(thread: t, indent: indent,
                      snippet: list.searchSnippets[t.id])
        }
            .buttonStyle(.plain)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(store.list.currentID == t.id ? Palette.accentText.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 12))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: archive ? nil : .destructive) {
                    list.archive(t, !archive)
                } label: {
                    LucideLabel(archive ? "取消归档" : "归档", archive ? "archive-restore" : "archive")
                }
                .tint(archive ? Palette.swipeNeutral : Palette.swipeDanger)
                // 真删：从电脑上抹掉，不走归档。
                Button(role: .destructive) { pendingDelete = t } label: {
                    LucideLabel("删除", "trash-2")
                }
                .tint(Palette.swipeDanger)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { renaming = t; renameText = t.displayTitle } label: {
                    LucideLabel("重命名", "pencil")
                }
                .tint(Palette.swipeAccent)
                // 归到项目 / 移出项目。项目归属是按 cwd 算的，
                // 所以这一项改的是会话的工作目录（见 ThreadListModel.move）。
                Button { moving = t } label: {
                    LucideLabel("移到项目", "folder-input")
                }
                .tint(Palette.swipeAccent)
            }
            .contextMenu {
                Button { renaming = t; renameText = t.displayTitle } label: {
                    LucideLabel("重命名", "pencil")
                }
                Button { moving = t } label: { LucideLabel("移到项目", "folder-input") }
                Button(role: .destructive) { pendingDelete = t } label: {
                    LucideLabel("删除", "trash-2")
                }
            }
            .accessibilityIdentifier("thread.row.wrap")
            .accessibilityAddTraits(store.list.currentID == t.id ? .isSelected : [])
    }

    /// 右下角新建会话按钮。
    private var chatPill: some View {
        Button {
            store.backToChat()
        } label: {
            HStack(spacing: 8) {
                LucideIcon("plus", size: 20)
                Text("新会话").font(Palette.F.bodyBold)
            }
            .foregroundStyle(Palette.iconInverted)
            .padding(.horizontal, 18)
            .frame(minHeight: 52)
            .background(Palette.buttonBg, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Pressable())
        .contextMenu {
            Button { showNew = true } label: {
                LucideLabel("选择项目和模型", "settings-2")
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("新建会话")
        .accessibilityHint("创建一个空白会话")
        .accessibilityIdentifier("list.new")
    }
}

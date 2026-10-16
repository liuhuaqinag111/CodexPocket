import SwiftUI

private struct NavigationPageHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.bold)).tracking(-0.6)
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("navigation.heading")
            Text(detail).font(Palette.F.note).foregroundStyle(Palette.textSub)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
    }
}

private struct NavigationEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LucideIcon(icon, size: 32).foregroundStyle(Palette.textSub)
            Text(title).font(Palette.F.bodyBold).foregroundStyle(Palette.text)
            Text(detail).font(Palette.F.note).foregroundStyle(Palette.textSub)
        }
        .padding(20).padding(.vertical, 20)
    }
}

private extension View {
    func navigationPlainRow() -> some View {
        self.listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

private struct NavigationListNotice: View {
    let loading: Bool
    let error: String?
    let retry: () -> Void

    var body: some View {
        if let error {
            Button(action: retry) {
                HStack(alignment: .top, spacing: 10) {
                    LucideIcon("circle-alert", size: 18).foregroundStyle(Palette.danger)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error).font(Palette.F.note)
                        Text("轻点重试").font(Palette.F.caption).foregroundStyle(Palette.accentText)
                    }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain).padding(.horizontal, 20)
        } else if loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在同步…").font(Palette.F.note).foregroundStyle(Palette.textSub)
            }.padding(.horizontal, 20).frame(minHeight: 44)
        }
    }
}

/// 列表页里能推入的子页面。
enum ListRoute: Hashable {
    case projects
    case library
    case project(Project)
}

/// 项目按目录组织，每行共享同一条内容轴线。
struct ProjectsView: View {
    @EnvironmentObject var store: AppCoordinator

    private var list: ThreadListModel { store.list }

    var body: some View {
        List {
            NavigationPageHeading(title: "项目", detail: "把上下文留在熟悉的工作目录里")
                .navigationPlainRow()
            if list.loading || list.banner != nil {
                NavigationListNotice(loading: list.loading, error: list.banner) { list.load() }
                    .navigationPlainRow()
            }
            if list.projects.isEmpty && !list.loading {
                NavigationEmptyState(icon: "folder", title: "还没有项目",
                                     detail: "电脑端创建的项目会同步到这里。")
                    .navigationPlainRow()
            }
            ForEach(list.projects) { p in
                NavigationLink(value: ListRoute.project(p)) {
                    HStack(spacing: 12) {
                        LucideIcon("folder", size: 22)
                            .foregroundStyle(Palette.accentText)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surface))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p.name)
                                .font(Palette.F.bodyBold)
                                .foregroundStyle(Palette.text)
                                .lineLimit(2)
                            if let root = p.roots.first {
                                Text(root)
                                    .font(Palette.F.caption)
                                    .foregroundStyle(Palette.textSub)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Text("\(list.count(in: p)) 条")
                            .font(Palette.F.caption)
                            .foregroundStyle(Palette.textFaint)
                    }
                    .frame(minHeight: 76)
                    .padding(.vertical, 12)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .accessibilityIdentifier("project.row")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .refreshable { list.load() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { list.startReconcile(); list.fetchThreads(); list.loadProjects() }
        .onDisappear { list.stopReconcile() }
    }
}

/// 一个项目下的会话。
struct ProjectDetailView: View {
    @EnvironmentObject var store: AppCoordinator
    let project: Project

    private var list: ThreadListModel { store.list }

    private var rows: [Thread] {
        list.threads.filter { list.project(of: $0)?.id == project.id }
    }

    var body: some View {
        List {
            NavigationPageHeading(title: project.name,
                                  detail: project.roots.first ?? "项目会话")
                .navigationPlainRow()
            if list.loading || list.banner != nil {
                NavigationListNotice(loading: list.loading, error: list.banner) { list.load() }
                    .navigationPlainRow()
            }
            if rows.isEmpty && !list.loading {
                NavigationEmptyState(icon: "message-circle", title: "这里还很安静",
                                     detail: "在这个项目里创建会话，继续你的工作。")
                    .navigationPlainRow()
            }
            ForEach(rows) { t in
                Button { store.open(t) } label: { ThreadRow(thread: t) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { list.archive(t, true) } label: {
                            LucideLabel("归档", "archive")
                        }
                        .tint(Palette.swipeDanger)
                    }
                    .accessibilityIdentifier("thread.row.wrap")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .refreshable { list.load() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { list.startReconcile(); list.fetchThreads() }
        .onDisappear { list.stopReconcile() }
    }
}

/// 库：已归档的会话。
struct LibraryView: View {
    @EnvironmentObject var store: AppCoordinator

    private var list: ThreadListModel { store.list }

    var body: some View {
        List {
            NavigationPageHeading(title: "已归档", detail: "收好完成的工作，需要时再继续")
                .navigationPlainRow()
            if list.loading || list.banner != nil {
                NavigationListNotice(loading: list.loading, error: list.banner) { list.load() }
                    .navigationPlainRow()
            }
            if list.archived.isEmpty && !list.loading {
                NavigationEmptyState(icon: "archive", title: "还没有归档的会话",
                                     detail: "归档会收起会话，同时保留完整记录。")
                    .navigationPlainRow()
            }
            ForEach(list.archived) { t in
                Button { store.open(t) } label: { ThreadRow(thread: t) }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { list.archive(t, false) } label: {
                            LucideLabel("取消归档", "archive-restore")
                        }
                        .tint(Palette.swipeAccent)
                    }
                    .accessibilityIdentifier("thread.row.wrap")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.bg)
        .refreshable { list.load() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { list.startReconcile(); list.fetchArchived() }
        .onDisappear { list.stopReconcile() }
    }
}

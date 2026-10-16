import SwiftUI

struct WorktreesView: View {
    @StateObject private var model: WorktreesFeatureModel
    @Environment(\.dismiss) private var dismiss
    let cwd: String
    let onOpenThread: (String) -> Void
    init(repository: WorkspaceRepositoryProtocol, cwd: String, onOpenThread: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: WorktreesFeatureModel(repository: repository))
        self.cwd = cwd
        self.onOpenThread = onOpenThread
    }
    var body: some View {
        NavigationStack {
            content
                .background(Palette.bg)
                .tint(Palette.accentText)
                .navigationTitle("Worktrees")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { Task { await refresh() } } label: {
                            LucideIcon("refresh-cw").frame(minWidth: 44, minHeight: 44)
                        }
                            .disabled(model.isLoading)
                            .accessibilityLabel("刷新 Worktrees")
                    }
                }
                .task(id: cwd) { await refresh() }
                .refreshable { await refresh() }
        }
        .accessibilityIdentifier("workspace.worktrees")
    }
    private func refresh() async { await model.refresh(cwd: cwd) }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.groups.isEmpty {
            ProgressView("正在读取 Worktrees").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.groups.isEmpty {
            WorkspaceStatusView(title: "读取失败", symbol: "git-branch", detail: error) {
                Task { await refresh() }
            }
        } else if model.groups.isEmpty {
            WorkspaceStatusView(title: "暂无工作树", symbol: "git-branch", detail: "独立分支中的会话会按工作树归类。")
        } else {
            List {
                if let error = model.errorMessage ?? model.chatErrorMessage {
                    Text(error).font(Palette.F.note).foregroundStyle(Palette.danger)
                }
                ForEach(model.groups) { group in
                    Section {
                        if group.threads.isEmpty {
                            Text(model.chatsLoaded ? "暂无会话" : "会话未加载")
                                .font(Palette.F.note).foregroundStyle(Palette.textSub)
                        }
                        ForEach(group.threads) { thread in
                            Button { onOpenThread(thread.id) } label: { WorkspaceThreadRow(thread: thread) }
                                .buttonStyle(.plain).accessibilityIdentifier("workspace.worktree.thread")
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowBackground(Palette.bg)
                                .listRowSeparatorTint(Palette.separatorFaint)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            LucideLabel(group.worktree.branch ?? "Detached HEAD", "git-branch")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                            Text(group.worktree.path).font(Palette.F.caption).textCase(nil)
                                .foregroundStyle(Palette.textSub).textSelection(.enabled)
                            if group.worktree.lockedReason != nil { Text("已锁定").foregroundStyle(Palette.warning) }
                        }.padding(.vertical, 12)
                    }
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
}

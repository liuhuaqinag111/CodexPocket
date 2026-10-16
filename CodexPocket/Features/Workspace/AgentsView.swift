import SwiftUI

struct AgentsView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var model: AgentsFeatureModel
    @Environment(\.dismiss) private var dismiss
    let threadID: String?
    let onOpenThread: (String) -> Void
    init(repository: WorkspaceRepositoryProtocol, threadID: String?, onOpenThread: @escaping (String) -> Void) {
        _model = StateObject(wrappedValue: AgentsFeatureModel(repository: repository))
        self.threadID = threadID
        self.onOpenThread = onOpenThread
    }
    var body: some View {
        NavigationStack {
            content
                .background(Palette.bg)
                .tint(Palette.accentText)
                .navigationTitle("Agents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { Task { await refresh() } } label: {
                            LucideIcon("refresh-cw").frame(minWidth: 44, minHeight: 44)
                        }
                            .disabled(model.isLoading)
                            .accessibilityLabel("刷新 Agents")
                    }
                }
                .task(id: threadID) { await refresh() }
                .refreshable { await refresh() }
        }
        .accessibilityIdentifier("workspace.agents")
    }
    private func refresh() async { await model.refresh(threadID: threadID) }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.rows.isEmpty {
            ProgressView("正在读取 Agents").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.rows.isEmpty {
            WorkspaceStatusView(title: "读取失败", symbol: "wifi-off", detail: error) {
                Task { await refresh() }
            }
        } else if model.rows.isEmpty {
            WorkspaceStatusView(title: "暂无协作任务", symbol: "users", detail: "当前会话的协作任务会集中显示在这里。")
        } else {
            List {
                Section {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) { summary }.font(.subheadline)
                    } else {
                        HStack { summary }.font(.subheadline)
                    }
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(Palette.danger) }
                ForEach(model.rows) { row in
                    Button { onOpenThread(row.thread.id) } label: {
                        HStack(spacing: 12) {
                            LucideIcon(row.depth == 0 ? "user-round" : "corner-down-right")
                                .frame(width: 24).foregroundStyle(Palette.textSub)
                            WorkspaceThreadRow(thread: row.thread)
                            Spacer(minLength: 0)
                            LucideIcon("chevron-right", size: 16).foregroundStyle(Palette.textFaint)
                        }.padding(.leading, CGFloat(min(row.depth, 5)) * 12)
                    }.buttonStyle(.plain).accessibilityIdentifier("workspace.agent.row")
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Palette.bg)
                        .listRowSeparatorTint(Palette.separatorFaint)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }
    @ViewBuilder private var summary: some View {
        Text("\(model.rows.count) 个协作任务").foregroundStyle(Palette.textSub)
        if !typeSize.isAccessibilitySize { Spacer() }
        Text("\(model.rows.filter { $0.thread.status.isRunning }.count) 个运行中")
            .foregroundStyle(Palette.success)
    }
}

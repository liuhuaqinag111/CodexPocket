import SwiftUI

/// 会话配置：切模型、推理强度，以及中断 / 压缩 / 分叉。
struct ThreadConfigSheet: View {
    @EnvironmentObject var store: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showUsage = false
    @State private var showFiles = false

    /// 当前会话**实际**在用的模型：会话自己记的优先，没有就退到
    /// 电脑端 `config.toml` 的全局模型。以前这里是空的，
    /// 看着就像"手机和电脑端不一致"。
    private var current: String { store.list.resolvedModel }

    /// 仅显示当前分组目录，旧会话模型不补进可选项。
    private var models: [ModelOption] { store.list.modelRows(current: current) }

    /// 当前模型支持的推理强度档位。目录里没有就用电脑端那份。
    private var efforts: [EffortOption] { store.list.effortsFor(current) }

    private var currentEffort: String { store.list.resolvedEffort }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Palette.S.xl) {
                    LucideLabel(store.chat.current?.cwd ?? "~", "folder")
                        .font(Palette.F.note)
                        .foregroundStyle(Palette.textSub)
                        .textSelection(.enabled)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("模型").sectionLabel()
                        if let error = store.list.modelCatalogError {
                            Text(error).font(Palette.F.caption).foregroundStyle(Palette.textSub)
                            Button("重新加载模型") { store.list.loadModels() }
                                .frame(minHeight: 44)
                        }
                        VStack(spacing: 0) {
                            ForEach(models) { m in
                                if m.id != models.first?.id { Hairline() }
                                Button {
                                    store.list.setModel(m.id)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(m.name).font(Palette.F.note)
                                                .foregroundStyle(Palette.text)
                                            if !m.detail.isEmpty {
                                                Text(m.detail).font(Palette.F.caption)
                                                    .foregroundStyle(Palette.textFaint)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        if m.id == current {
                                            LucideIcon("check", size: 20)
                                                .foregroundStyle(Palette.accentText)
                                        }
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 14)
                                    .frame(minHeight: 52)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(m.id == current ? .isSelected : [])
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Palette.R.card)
                            .fill(Palette.surface))
                    }

                    if !efforts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("推理强度").sectionLabel()
                            VStack(spacing: 0) {
                                ForEach(efforts) { e in
                                    if e.id != efforts.first?.id { Hairline() }
                                    Button {
                                        store.list.setEffort(e.id)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            Text(e.name).font(Palette.F.note)
                                                .foregroundStyle(Palette.text)
                                            Spacer(minLength: 0)
                                            if e.id == currentEffort {
                                                LucideIcon("check", size: 20)
                                                    .foregroundStyle(Palette.accentText)
                                            }
                                        }
                                        .padding(.horizontal, 16).padding(.vertical, 14)
                                        .frame(minHeight: 52)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits(e.id == currentEffort ? .isSelected : [])
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: Palette.R.card)
                                .fill(Palette.surface))
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("操作").sectionLabel()
                        VStack(spacing: 0) {
                            actionRow("circle-stop", "中断当前任务", Palette.danger) {
                                store.chat.interrupt(); dismiss()
                            }
                            actionRow("shrink", "压缩上下文") {
                                store.chat.compact(); dismiss()
                            }
                            actionRow("git-branch", "从此处分叉") {
                                store.chat.fork(); dismiss()
                            }
                            // 回退：把会话历史退回上一轮之前。
                            // 服务端原话：只改持久化的对话历史，**不动文件**。
                            actionRow("undo-2", "回退上一轮", Palette.warning) {
                                store.chat.revertLast(); dismiss()
                            }
                            actionRow("chart-no-axes-combined", "本会话用量", Palette.text) { showUsage = true }
                            // 文件树：服务端 fs/* 一直有，之前一个都没接。
                            actionRow("folder", "浏览项目文件", Palette.text, id: "config.files") { showFiles = true }
                        }
                        .background(RoundedRectangle(cornerRadius: Palette.R.card)
                            .fill(Palette.surface))
                    }
                }
                .padding(UI.gutter)
            }
            .background(Palette.bg)
            .tint(Palette.accentText)
            .toolbarBackground(Palette.bg, for: .navigationBar)
            .sheet(isPresented: $showUsage) { UsageSheet() }
            .sheet(isPresented: $showFiles) {
                FileBrowserView(repository: store.fileRepository, root: store.chat.current?.cwd ?? "")
            }
            .navigationTitle("会话配置")
            .onAppear {
                store.list.loadModels()
                store.list.refreshConfiguration(force: true)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 分割线 + 操作行。
    /// 单独抽出来是因为 VStack 的 ViewBuilder 最多只吃 10 个子视图，
    /// 平铺写 6 个 action + 5 条 Hairline 会直接编译不过（报 "extra argument in call"）。
    private func actionRow(_ icon: String, _ title: String, _ tint: Color = Palette.text,
                           id: String = "", tap: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Hairline()
            action(icon, title, tint, id: id, tap: tap)
        }
    }

    private func action(_ icon: String, _ title: String, _ tint: Color = Palette.text,
                        id: String = "", tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                LucideIcon(icon, size: 20)
                    .foregroundStyle(tint).frame(width: 20)
                Text(title).font(Palette.F.note).foregroundStyle(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

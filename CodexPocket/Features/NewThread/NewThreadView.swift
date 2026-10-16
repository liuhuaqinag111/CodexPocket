import SwiftUI

/// 新建会话：选项目、模型、推理强度，可带首条消息直接开跑。
struct NewThreadView: View {
    @EnvironmentObject var store: AppCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var cwd: String?
    @State private var model = ""
    @State private var effort = ""
    @State private var creating = false
    @State private var creationError: String?

    /// 目录 + 电脑端全局模型兜底行。默认选中全局模型，
    /// 手机新建的会话才跟电脑端用同一个模型。
    private var models: [ModelOption] {
        store.list.modelRows(current: model.isEmpty ? store.list.globalModel : model)
    }

    private var efforts: [EffortOption] {
        store.list.effortsFor(model.isEmpty ? store.list.globalModel : model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("从一个想法开始")
                            .font(.largeTitle.weight(.bold)).tracking(-0.6)
                            .foregroundStyle(Palette.text)
                        Text("写下任务，选好工作环境，剩下的交给 Codex。")
                            .font(Palette.F.note).foregroundStyle(Palette.textSub)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("任务").sectionLabel()
                        TextField("你想完成什么？", text: $text,
                                  prompt: Text("你想完成什么？").foregroundColor(Palette.placeholder), axis: .vertical)
                            .font(Palette.F.body)
                            .foregroundStyle(Palette.text)
                            .lineLimit(4...8)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: Palette.R.card)
                                .fill(Palette.surface))
                            .accessibilityIdentifier("new.text")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("项目").sectionLabel()
                        VStack(spacing: 0) {
                            pickerRow(title: "不指定（默认目录）",
                                      sub: store.settings.newThreadCwd,
                                      selected: cwd == nil) {
                                cwd = nil
                            }
                            ForEach(store.list.projects) { p in
                                Hairline()
                                pickerRow(title: p.name, sub: p.roots.first ?? "",
                                          selected: cwd == p.roots.first) {
                                    cwd = p.roots.first
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Palette.R.card)
                            .fill(Palette.surface))
                    }

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
                                pickerRow(title: m.name, sub: m.detail, selected: (model.isEmpty ? store.list.globalModel : model) == m.id) {
                                    model = m.id
                                    effort = m.defaultEffort
                                }
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: Palette.R.card)
                            .fill(Palette.surface))
                    }

                    if !efforts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("推理强度").sectionLabel()
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                                ForEach(efforts) { e in
                                    Button { effort = e.id } label: {
                                        Text(e.name)
                                            .font(Palette.F.note)
                                            .foregroundStyle(effort == e.id
                                                             ? Palette.iconInverted : Palette.text)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .padding(.horizontal, 8)
                                            .background(RoundedRectangle(cornerRadius: 12).fill(effort == e.id
                                                                       ? Palette.buttonBg
                                                                       : Palette.surface))
                                    }
                                    .buttonStyle(Pressable())
                                    .accessibilityAddTraits(effort == e.id ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Palette.bg)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { createFooter }
        }
        .onAppear {
            store.list.loadModels()
            if model.isEmpty { model = store.list.modelForNewThread }
            if effort.isEmpty { effort = store.list.effortForNewThread }
        }
    }

    private func pickerRow(title: String, sub: String = "",
                           selected: Bool, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(Palette.F.body).foregroundStyle(Palette.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !sub.isEmpty {
                        Text(sub).font(Palette.F.caption)
                            .foregroundStyle(Palette.textSub).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if selected {
                    LucideIcon("check", size: 18)
                        .foregroundStyle(Palette.accentText)
                }
            }
            .padding(16).frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var createFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let creationError {
                Text(creationError).font(Palette.F.caption)
                    .foregroundStyle(Palette.danger)
            }
            Button(action: create) {
                HStack(spacing: 10) {
                    if creating { ProgressView().tint(Palette.iconInverted) }
                    Text(creating ? "正在创建…" : "创建会话")
                    Spacer()
                    if !creating { LucideIcon("arrow-up-right", size: 20) }
                }
                .font(Palette.F.bodyBold).foregroundStyle(Palette.iconInverted)
                .padding(.horizontal, 18).frame(minHeight: 52)
                .background(Palette.buttonBg, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(Pressable()).disabled(creating)
            .accessibilityIdentifier("new.create")
        }
        .padding(20).background(Palette.bg)
    }

    private func create() {
        guard !creating else { return }
        creating = true
        creationError = nil
        // 没选项目就走设置里的默认目录（空 = `~`）。传 nil 的话
        // 服务端会把 cwd 兜成 `/`（实测），等于扫全盘。
        store.list.create(cwd: cwd ?? store.settings.newThreadCwd,
                          model: model, effort: effort,
                          first: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            id in
            creating = false
            guard let id else {
                creationError = store.list.banner ?? "创建没有成功，请重试。内容已保留。"
                return
            }
            dismiss()
            if let t = store.list.thread(id) { store.open(t) }
        }
    }
}

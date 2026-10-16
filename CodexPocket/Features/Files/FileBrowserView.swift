import SwiftUI

@MainActor
struct FileBrowserView: View {
    @StateObject private var model: FilesModel
    @Environment(\.dismiss) private var dismiss
    @State private var retryFile: String?

    init(repository: FileRepository, root: String) {
        _model = StateObject(wrappedValue: FilesModel(repository: repository, root: root))
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.breadcrumbs) { crumb in
                    if crumb.path != model.root {
                        LucideIcon("chevron-right", size: 14)
                            .foregroundStyle(Palette.textFaint)
                    }
                    Button { model.enterDirectory(crumb.path) } label: {
                        Text(crumb.name).font(Palette.F.note)
                            .foregroundStyle(crumb.path == model.currentPath ? Palette.text : Palette.textSub)
                            .lineLimit(1).frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开文件夹 " + crumb.name)
                }
            }
            .padding(.horizontal, 20)
        }
        .background(Palette.surface)
        .accessibilityIdentifier("files.breadcrumbs")
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                LucideIcon("x").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(model.isBusy)
            .accessibilityLabel("关闭文件浏览器")
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { model.enterDirectory(model.root) } label: {
                LucideIcon("house").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(model.currentPath == model.root)
            .accessibilityLabel("返回项目根目录")
            .accessibilityIdentifier("files.home")
            Button { model.retryDirectory(model.currentPath) } label: {
                LucideIcon("refresh-cw").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(model.currentDirectory.isLoading)
            .accessibilityLabel("刷新文件列表")
            .accessibilityIdentifier("files.refresh")
            filterMenu
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("项目类型", selection: $model.filter) {
                ForEach(FileListFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            Toggle("显示隐藏文件", isOn: $model.showHidden)
        } label: {
            LucideIcon("list-filter")
                .foregroundStyle(model.showHidden || model.filter != .all ? Palette.accentText : Palette.textSub)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("筛选文件")
        .accessibilityIdentifier("files.filter")
    }

    @ViewBuilder
    private var directoryContent: some View {
        let directory = model.currentDirectory
        if directory.isLoading && !directory.isLoaded {
            ProgressView("正在读取文件夹")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = directory.error, directory.entries.isEmpty {
            FileStatusView(title: "读取文件夹失败", detail: error, symbol: "folder-search") {
                model.retryDirectory(model.currentPath)
            }
        } else if model.rows.isEmpty {
            FileStatusView(title: model.query.isEmpty && model.filter == .all
                           ? "文件夹为空" : "没有匹配的文件",
                           detail: model.query.isEmpty ? "这里的文件会显示在此处。" : "试试其他名称，或调整筛选条件。", symbol: "folder")
        } else {
            List {
                if let error = directory.error {
                    FileDirectoryStatus(message: error) { model.retryDirectory(model.currentPath) }
                }
                ForEach(model.rows) { row in treeRow(row) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func treeRow(_ row: FileTreeRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    if row.entry.isDir { model.toggleDirectory(row.path) }
                    else {
                        retryFile = row.path
                        model.openFile(row.path)
                    }
                } label: {
                    FileTreeLabel(row: row, expanded: model.expandedPaths.contains(row.path),
                                  isOpening: model.openingPath == row.path)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier(row.entry.isDir ? "files.dir" : "files.file")
                if row.entry.isDir {
                    Button { model.enterDirectory(row.path) } label: {
                        LucideIcon("arrow-right", size: 18)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("进入文件夹 " + row.entry.name)
                }
            }
            directoryStatus(row)
        }
        .padding(.leading, CGFloat(min(row.depth, 6)) * 16)
        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 12))
        .listRowBackground(Palette.bg)
        .listRowSeparatorTint(Palette.separatorFaint)
    }

    @ViewBuilder
    private func directoryStatus(_ row: FileTreeRow) -> some View {
        if row.entry.isDir, model.expandedPaths.contains(row.path),
           let state = model.directories[row.path] {
            if state.isLoading {
                ProgressView().padding(.leading, 32).padding(.vertical, 8)
            } else if let error = state.error {
                FileDirectoryStatus(message: error) { model.retryDirectory(row.path) }
                    .padding(.leading, 32)
            } else if state.isLoaded && state.entries.isEmpty {
                Text("空文件夹").font(Palette.F.caption).foregroundStyle(Palette.textFaint)
                    .padding(.leading, 32).padding(.vertical, 8)
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                breadcrumbs
                Divider()
                directoryContent
            }
            .background(Palette.bg)
            .tint(Palette.accentText)
            .toolbarBackground(Palette.bg, for: .navigationBar)
            .navigationTitle("文件")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, prompt: "搜索文件")
            .toolbar { browserToolbar }
            .onAppear { model.load() }
        }
        .sheet(item: Binding(get: { model.document }, set: { value in
            if value == nil { model.requestCloseDocument() }
        })) { _ in
            FileEditorView(model: model)
        }
        .alert("无法打开文件", isPresented: Binding(
            get: { model.document == nil && model.fileError != nil },
            set: { if !$0 { model.fileError = nil } })) {
                Button("重试") {
                    if let retryFile { model.openFile(retryFile) }
                }
                Button("取消", role: .cancel) { model.fileError = nil }
            } message: {
                Text(model.fileError ?? "")
            }
        .interactiveDismissDisabled(model.isBusy)
        .accessibilityIdentifier("files.sheet")
    }
}

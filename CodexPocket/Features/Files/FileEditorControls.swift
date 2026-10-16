import SwiftUI

extension FileEditorView {
    @ToolbarContentBuilder
    var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("完成") { model.requestCloseDocument() }
                .disabled(model.isBusy)
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { model.isEditing.toggle() } label: {
                LucideIcon(model.isEditing ? "eye" : "pencil")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(model.isBusy)
            .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(model.isEditing ? "预览" : "编辑")
            .accessibilityIdentifier("files.edit")
            Button { model.saveDocument() } label: {
                LucideIcon("check").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!model.hasUnsavedChanges || model.isBusy)
            .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("保存文件")
            .accessibilityIdentifier("files.save")
        }
    }

    var editorFooter: some View {
        HStack {
            Text(model.isSaving ? "正在保存" : model.hasUnsavedChanges ? "未保存" : "已同步")
            Spacer()
            Text("\(model.draft.components(separatedBy: "\n").count) 行")
        }
        .font(Palette.F.caption).foregroundStyle(Palette.textSub)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Palette.surface)
    }
}

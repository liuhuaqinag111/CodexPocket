import SwiftUI

@MainActor
struct FileEditorView: View {
    @ObservedObject var model: FilesModel
    @State var remotePreview: FileDocument?
    @State var confirmRemote = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorNotices
                if model.isEditing {
                    TextEditor(text: $model.draft)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .foregroundStyle(Palette.text)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("files.editor")
                } else {
                    FileTextPreview(text: model.draft)
                }
            }
            .background(Palette.bg)
            .tint(Palette.accentText)
            .toolbarBackground(Palette.bg, for: .navigationBar)
            .navigationTitle(ComputerPath.lastComponent(model.document?.path ?? ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { editorFooter }
        }
        .interactiveDismissDisabled(model.hasUnsavedChanges || model.isBusy)
        .alert("保留更改？", isPresented: $model.showDiscardConfirmation) {
            Button("保存并关闭") { model.saveDocument(closeAfterSaving: true) }
            Button("放弃更改", role: .destructive) { model.discardAndClose() }
            Button("取消", role: .cancel) { model.cancelDiscard() }
        }
        .alert("使用远端版本？", isPresented: $confirmRemote) {
            Button("使用远端", role: .destructive) { model.acceptRemoteVersion() }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $remotePreview) { remote in
            NavigationStack {
                FileTextPreview(text: remote.text)
                    .background(Palette.bg)
                    .navigationTitle("远端版本")
                    .toolbar { Button("完成") { remotePreview = nil } }
            }
        }
        .accessibilityIdentifier("files.preview")
    }
}

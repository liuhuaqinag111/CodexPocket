import SwiftUI

extension FileEditorView {
    @ViewBuilder
    var editorNotices: some View {
        if let remote = model.conflict {
            VStack(alignment: .leading, spacing: 8) {
                LucideLabel("远端文件已更改", "triangle-alert")
                    .foregroundStyle(Palette.warning)
                HStack {
                    Button("查看远端") { remotePreview = remote }.frame(minHeight: 44)
                    Spacer()
                    Button("使用远端") { confirmRemote = true }.frame(minHeight: 44)
                }
            }
            .font(Palette.F.note).padding(.horizontal, 20).padding(.top, 16)
            .background(Palette.surface)
        }
        if let error = model.fileError {
            LucideLabel(error, "circle-alert")
                .font(Palette.F.note).foregroundStyle(Palette.danger)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FileTextPreview: View {
    let text: String
    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(20)
                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height,
                           alignment: .topLeading)
            }
        }
    }
}

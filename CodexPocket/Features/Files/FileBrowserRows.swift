import SwiftUI

struct FileTreeLabel: View {
    let row: FileTreeRow
    let expanded: Bool
    let isOpening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fileIcon: String {
        switch (row.entry.name as NSString).pathExtension.lowercased() {
        case "swift", "js", "ts", "tsx", "jsx", "py", "go", "rs", "java", "kt", "c", "h", "cpp":
            return "file-code-2"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "file-json-2"
        case "md", "txt", "log": return "file-text"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "image"
        default: return "file"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if row.entry.isDir {
                LucideIcon("chevron-right", size: 14)
                    .foregroundStyle(Palette.textFaint).frame(width: 12)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: expanded)
            }
            LucideIcon(row.entry.isDir ? (expanded ? "folder-open" : "folder") : fileIcon)
                .foregroundStyle(row.entry.isDir ? Palette.accentText : Palette.textSub)
                .frame(width: 24)
            Text(row.entry.name).font(Palette.F.body).foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if row.entry.isSymlink {
                LucideIcon("link", size: 14).foregroundStyle(Palette.textSub)
            }
            if isOpening { ProgressView().frame(width: 24) }
        }
        .frame(minHeight: 44).contentShape(Rectangle())
    }
}

struct FileDirectoryStatus: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message).font(Palette.F.caption).foregroundStyle(Palette.textSub)
            Spacer(minLength: 8)
            Button(action: retry) {
                LucideIcon("refresh-cw", size: 18).frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("重试读取文件夹")
        }
    }
}

struct FileStatusView: View {
    let title: String
    let detail: String?
    let symbol: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            LucideIcon(symbol, size: 32).foregroundStyle(Palette.accentText)
                .frame(width: 64, height: 64)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.text)
            if let detail {
                Text(detail).font(Palette.F.note).foregroundStyle(Palette.textSub)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(action: retry) {
                    LucideLabel("重新读取", "refresh-cw").frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("files.retry")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

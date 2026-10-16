import SwiftUI

struct WorkspaceStatusView: View {
    let title: String
    let symbol: String
    var detail: String?
    var retry: (() -> Void)?
    var body: some View {
        VStack(spacing: 12) {
            LucideIcon(symbol, size: 32).foregroundStyle(Palette.accentText)
                .frame(width: 64, height: 64)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(Palette.text)
            if let detail { Text(detail).font(Palette.F.note).foregroundStyle(Palette.textSub) }
            if let retry { Button("重新读取", action: retry).frame(minHeight: 44).buttonStyle(.bordered) }
        }
        .multilineTextAlignment(.center).padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WorkspaceThreadRow: View {
    let thread: WorkspaceThread
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(thread.title).font(Palette.F.body.weight(.medium)).foregroundStyle(Palette.text).lineLimit(2)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) { metadata }
                    .font(.caption)
            } else {
                HStack(spacing: 8) { metadata }.font(.caption)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
    @ViewBuilder private var metadata: some View {
        LucideLabel(thread.status.label, thread.status.isRunning ? "activity" : "circle-check")
            .foregroundStyle(thread.status.isRunning ? Palette.success : Palette.textSub)
        if let role = thread.role {
            Text(role == "implementer" ? "实现" : role == "reviewer" ? "审查" : role)
                .foregroundStyle(Palette.textSub)
        }
        if thread.isArchived { Text("已归档").foregroundStyle(Palette.textSub) }
    }
}

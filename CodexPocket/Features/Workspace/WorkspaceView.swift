import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var store: AppCoordinator
    @State private var tab = 0
    private var cwd: String { store.chat.current?.cwd ?? store.settings.defaultCwd }

    var body: some View {
        VStack(spacing: 0) {
            Picker("工作区", selection: $tab) {
                Text("文件").tag(0)
                Text("Agents").tag(1)
                Text("Worktrees").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .accessibilityIdentifier("workspace.tabs")
            Group {
                switch tab {
                case 1:
                    AgentsView(repository: store.workspaceRepository,
                               threadID: store.list.currentID, onOpenThread: open)
                case 2:
                    WorktreesView(repository: store.workspaceRepository, cwd: cwd, onOpenThread: open)
                default:
                    FileBrowserView(repository: store.fileRepository, root: cwd)
                }
            }
        }
        .background(Palette.bg)
        .tint(Palette.accentText)
        .accessibilityIdentifier("workspace.sheet")
    }
    @Environment(\.dismiss) private var dismiss
    private func open(_ id: String) {
        store.requestOpenThread(id)
        dismiss()
    }
}

import SwiftUI

struct EmptyChatView: View {
    @EnvironmentObject var store: AppCoordinator
    @State private var showWorkspace = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CircleButton(system: "panel-left", identifier: "chat.menu") { store.showDrawer = true }
                    .accessibilityLabel("打开会话列表")
                Spacer()
                ConnectionIndicator()
                CircleButton(system: "square-pen", identifier: "chat.new") { store.composer.newThread() }
                    .accessibilityLabel("新建会话")
            }
            .padding(.horizontal, UI.gutter).padding(.vertical, 8)
            StatusStrip()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("CODEX POCKET")
                        .font(Palette.F.caption.weight(.semibold)).tracking(2)
                        .foregroundStyle(Palette.accentText)
                    Text("把想法，\n变成下一步。")
                        .font(.system(.largeTitle, design: .default).weight(.bold))
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("chat.empty")
                    Text("接上电脑，随时继续你的工作。")
                        .font(Palette.F.body).foregroundStyle(Palette.textSub)
                    Hairline()
                    Button { store.showDrawer = true } label: {
                        homeAction("继续一个会话", detail: "回到最近的任务", icon: "messages-square")
                    }
                    .buttonStyle(.plain)
                    Button { showWorkspace = true } label: {
                        homeAction("打开工作区", detail: "文件、协作与工作树", icon: "panels-top-left")
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("chat.workspace")
                }
                .padding(.horizontal, UI.gutter).padding(.top, 48).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            Composer()
        }
        .background(Palette.bg.ignoresSafeArea().onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        .sheet(isPresented: $showWorkspace) { WorkspaceView() }
    }

    private func homeAction(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 16) {
            LucideIcon(icon, size: 22).foregroundStyle(Palette.accentText)
                .frame(width: 44, height: 44).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Palette.F.body.weight(.medium)).foregroundStyle(Palette.text)
                Text(detail).font(Palette.F.caption).foregroundStyle(Palette.textSub)
            }
            Spacer(minLength: 4)
            LucideIcon("arrow-up-right", size: 18).foregroundStyle(Palette.textSub)
        }
        .frame(minHeight: 60).contentShape(Rectangle())
    }
}

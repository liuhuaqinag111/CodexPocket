import SwiftUI

struct ConnectionIndicator: View {
    @EnvironmentObject var store: AppCoordinator
    @State private var details = false

    var body: some View {
        Button { details = true } label: {
            Circle()
                .fill(store.state.isReady ? Palette.success : Palette.warning)
                .frame(width: 7, height: 7)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.state.label)
        .accessibilityIdentifier("connection.details")
        .sheet(isPresented: $details) {
            NavigationStack {
                Form {
                    LabeledContent("状态", value: store.state.label)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("电脑").font(Palette.F.caption).foregroundStyle(Palette.textSub)
                        Text(store.settings.displayHost).textSelection(.enabled)
                    }
                    Text(store.rpc.diagnosticSnapshot().summaryLine)
                        .font(.caption.monospaced()).textSelection(.enabled)
                    Button("重新连接") { store.rpc.reconnectNow() }
                }
                .scrollContentBackground(.hidden)
                .background(Palette.bg)
                .navigationTitle("连接状态")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { details = false }
                    }
                }
            }
        }
    }
}

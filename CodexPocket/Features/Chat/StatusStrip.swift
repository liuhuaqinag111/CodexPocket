import SwiftUI

/// 顶栏下方状态与连接诊断条：在连接异常或用户查看诊断时提供清晰依据。
struct StatusStrip: View {
    @EnvironmentObject var store: AppCoordinator
    @State private var showDetails = false

    private var state: WebSocketTransport.State { store.state }
    private var diag: WebSocketTransport.DiagnosticSnapshot { store.rpc.diagnosticSnapshot() }

    var body: some View {
        if let line = text {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    if case .reconnecting = state {
                        ProgressView().controlSize(.mini).tint(Palette.warning)
                    } else {
                        Circle().fill(dot).frame(width: 7, height: 7)
                    }

                    Text(line)
                        .font(Palette.F.caption)
                        .foregroundStyle(Palette.textSub)
                        .lineLimit(3)

                    Spacer(minLength: 0)

                    Button(showDetails ? "收起" : "诊断") {
                        showDetails.toggle()
                    }
                    .font(Palette.F.caption)
                    .frame(minHeight: 44)
                    .foregroundStyle(Palette.textSub)

                    if case .failed = state {
                        Button("重连") { store.rpc.reconnectNow() }
                            .font(Palette.F.caption)
                            .frame(minHeight: 44)
                            .foregroundStyle(Palette.accentText)
                    }
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 44)

                if showDetails {
                    HStack {
                        Text(diag.summaryLine)
                            .font(Palette.F.mono)
                            .foregroundStyle(Palette.textFaint)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                        Button("上传日志") {
                            Task { @MainActor in
                                let ok = await FrameLog.upload(store.settings) != nil
                                store.banner = ok ? "帧日志已上传" : "上传失败"
                            }
                        }
                        .font(Palette.F.caption)
                        .frame(minHeight: 44)
                        .foregroundStyle(Palette.accentText)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
            }
            .background(Palette.warning.opacity(0.10))
            .accessibilityIdentifier("chat.status")
            .accessibilityValue(line)
        }
    }

    private var text: String? {
        switch state {
        case .ready: return nil
        case .idle, .connecting: return "正在连接电脑…"
        case .reconnecting(let n): return n <= 1 ? "连接断了，正在重连…" : "连接断了，第 \(n) 次重连…"
        case .failed(let m): return m
        }
    }

    private var dot: Color {
        switch state {
        case .ready: return Palette.success
        case .failed: return Palette.danger
        default: return Palette.warning
        }
    }
}

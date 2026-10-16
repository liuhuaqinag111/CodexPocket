import SwiftUI


struct ApprovalRow: View {
    @EnvironmentObject var store: AppCoordinator
    let request: Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LucideIcon(request.isCommand ? "terminal" : "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.warning)
                Text(request.title).font(Palette.F.note).foregroundStyle(Palette.text)
                Spacer(minLength: 0)
            }
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(Palette.F.mono)
                    .foregroundStyle(Palette.textSub)
                    .lineLimit(4)
            }
            HStack(spacing: 10) {
                Button { store.resolve(request, accept: true) } label: {
                    Text("允许").font(Palette.F.bodyBold)
                        .foregroundStyle(Palette.iconInverted)
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.buttonBg))
                }
                .buttonStyle(Pressable())
                .accessibilityIdentifier("approval.allow")

                Button { store.resolve(request, accept: false) } label: {
                    Text("拒绝").font(Palette.F.bodyBold)
                        .foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.surface))
                }
                .buttonStyle(Pressable())
                .accessibilityIdentifier("approval.deny")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Palette.R.card).fill(Palette.elevated))
    }
}

/// 服务端队列中的待发消息。
struct QueueRow: View {
    @EnvironmentObject var chat: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                LucideIcon("clock").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textFaint)
                Text("已排队，尚未发送")
                    .font(Palette.F.note).foregroundStyle(Palette.textSub)
                Spacer(minLength: 0)
            }
            ForEach(chat.queued) { q in
                HStack(spacing: 8) {
                    Text(q.text).font(Palette.F.note).foregroundStyle(Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("取消") { chat.cancelQueued(q) }
                        .font(Palette.F.caption).foregroundStyle(Palette.textFaint)
                        .frame(minHeight: 44)
                }
            }
            // 「现在就跑」要求本连接先 resume 过这个会话；被电脑端占着时
            // 服务端会直接拒（"resume the thread before starting…"）。
            // 与其给一个点了报错的按钮，不如说清楚谁在执行。
            if chat.desktopLocked {
                Text("电脑回复结束后会自动发送，也可以取消")
                    .font(Palette.F.caption).foregroundStyle(Palette.textFaint)
                        .frame(minHeight: 44)
            } else {
                Button("现在就跑") { chat.runQueuedNow() }
                    .frame(minHeight: 44)
                    .font(Palette.F.note)
                    .foregroundStyle(Palette.accentText)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Palette.R.card).fill(Palette.elevated))
    }
}

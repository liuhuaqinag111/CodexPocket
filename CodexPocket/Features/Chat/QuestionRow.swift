import SwiftUI

/// agent 反过来问用户的问题。
///
/// 以前 `agentMessage.questions` 只解析不渲染 —— agent 停在那儿等人答，
/// 而用户看到的是"它不动了"，只能干等或重发。
struct QuestionRow: View {
    @EnvironmentObject var store: AppCoordinator
    let prompts: [Question]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(prompts) { q in
                VStack(alignment: .leading, spacing: 8) {
                    if !q.header.isEmpty {
                        Text(q.header)
                            .font(Palette.F.caption)
                            .foregroundStyle(Palette.textFaint)
                    }
                    if !q.text.isEmpty {
                        Text(q.text)
                            .font(Palette.F.body)
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !q.options.isEmpty { options(q) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Palette.R.card).fill(Palette.elevated))
        .accessibilityIdentifier("chat.question")
    }

    private func options(_ q: Question) -> some View {
        VStack(spacing: 8) {
            ForEach(q.options) { o in
                Button { store.chat.answer(q, option: o) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.label)
                            .font(Palette.F.bodyBold)
                            .foregroundStyle(Palette.text)
                        if !o.detail.isEmpty {
                            Text(o.detail)
                                .font(Palette.F.caption)
                                .foregroundStyle(Palette.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.surface))
                }
                .buttonStyle(Pressable())
                .accessibilityIdentifier("chat.question.option")
            }
        }
    }
}

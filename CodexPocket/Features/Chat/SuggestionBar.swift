import SwiftUI

/// 输入框上方的补全面板（`/` 命令、`@` 文件）。
///
/// 只在真的有待选项时占位 —— 面板空白时不留高度，
/// 否则输入框会凭空往上跳一下。
struct SuggestionBar: View {
    @EnvironmentObject var store: AppCoordinator

    private var c: ComposerModel { store.composer }

    var body: some View {
        if c.suggestionKind != .none && !c.suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(c.suggestions) { s in
                        Button { c.accept(s) } label: { chip(s) }
                            .buttonStyle(Pressable())
                            .accessibilityIdentifier("composer.suggestion")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }

            .accessibilityIdentifier("composer.suggestions")
        }
    }

    private func chip(_ s: Suggestions.Item) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.title)
                .font(Palette.F.note)
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            if !s.detail.isEmpty {
                Text(s.detail)
                    .font(Palette.F.caption)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(width: 170, alignment: .leading)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Palette.inputBg))
    }
}

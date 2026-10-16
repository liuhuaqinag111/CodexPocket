import SwiftUI

/// 共用小组件。层级依靠系统材质、明度和留白，不额外叠装饰。
enum UI {
    /// 屏幕左右安全边距。
    static let gutter: CGFloat = 20
}

/// 0.5pt 分隔线。
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Palette.separatorFaint).frame(height: 0.5)
    }
}

/// 可折叠项目标题，保持完整触摸区并显示会话数。
struct GroupHeader: View {
    let title: String
    let count: Int
    let open: Bool
    let canToggle: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: { if canToggle { toggle() } }) {
                HStack(spacing: 12) {
                LucideIcon(title == "已归档" ? "archivebox" : "folder")
                    .font(Palette.F.note.weight(.semibold))
                    .foregroundStyle(Palette.textSub)
                Text(title)
                    .font(Palette.F.group)
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(Palette.F.caption)
                    .foregroundStyle(Palette.textFaint)
                if canToggle {
                    LucideIcon("chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.textFaint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .animation(Motion.quick, value: open)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.99))
        .disabled(!canToggle)
        .accessibilityValue(open ? "已展开" : "已收起")
    }
}

/// 顶栏：左按钮 / 中间标题 / 右按钮。背景透明。
struct NavBar<Left: View, Center: View, Right: View>: View {
    let left: Left
    let center: Center
    let right: Right

    var body: some View {
        HStack(spacing: 4) {
            left
            center.frame(maxWidth: .infinity)
            right
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

/// 顶栏上的轻材质圆形按钮。
struct CircleButton: View {
    let system: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 20
    var bg: Color = Palette.controlBg
    var tint: Color = Palette.controlIcon
    var identifier: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(system, size: iconSize)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable())
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// 顶栏上的无底图标按钮。
struct BarButton: View {
    let system: String
    var size: CGFloat = 20
    var tint: Color = Palette.textSub
    var identifier: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(system, size: size)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// 底部 sheet 的标题栏（新建会话、模型选择共用）。
struct SheetHeader: View {
    let title: String
    let done: () -> Void

    var body: some View {
        HStack {
            Text(title).font(Palette.F.title).foregroundStyle(Palette.text)
            Spacer()
            Button("完成", action: done)
                .font(Palette.F.note.weight(.semibold))
                .foregroundStyle(Palette.accentText)
        }
        .padding(.horizontal, UI.gutter)
        .padding(.vertical, Palette.S.m)
    }
}

/// 搜索框：36 高、圆角 10。
struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            LucideIcon("magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.textFaint)
            TextField("搜索会话", text: $text)
                .font(Palette.F.body)
                .foregroundStyle(Palette.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    LucideIcon("xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.textFaint)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: Palette.R.field, style: .continuous)
            .fill(Palette.surface))
    }
}

extension Text {
    /// 小标题：12pt 半粗、大写、加字距。
    func sectionLabel() -> some View {
        self.font(Palette.F.group)
            .foregroundStyle(Palette.textFaint)
            .textCase(.uppercase)
            .tracking(0)
    }
}

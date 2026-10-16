import SwiftUI
import UIKit

/// 动效曲线（严格采用 Emil Kowalski & WWDC Designing Fluid Interfaces 物理弹簧体系）。
///
/// 核心原则：
///   1. 物理阻尼（Critically Damped）：默认 Damping 1.0，绝不产生无意义的晃动与眩晕。
///   2. 动量继承（Velocity Handoff）：手势结束时继承释放速度。
///   3. 零延迟即时响应（Respond on pointer-down）：按压瞬时 0.96 形变 + 物理级触觉反馈。
///   4. 永不锁死（Interruptible & Redirectable）：动画中随时可被打断反向。
enum Motion {
    /// 默认物理弹簧：干净收敛，手势过程中可随时反向。
    static var base: Animation {
        UIAccessibility.isReduceMotionEnabled ? fade : .spring(response: 0.30, dampingFraction: 1.0)
    }
    
    /// 高频控件切换：短促、不抢内容注意力。
    static var quick: Animation {
        UIAccessibility.isReduceMotionEnabled ? fade : .spring(response: 0.20, dampingFraction: 1.0)
    }
    
    /// 物理动量弹簧（带有用户甩动手势的操作）：response 0.30s, damping 0.82 (微回弹)
    static let bounce = Animation.spring(response: 0.30, dampingFraction: 0.82)
    
    /// 流畅淡入淡出（非位移类内容呈现）
    static let fade = Animation.easeOut(duration: 0.16)
    
    /// 流式打字增量淡入
    static let stream = Animation.easeOut(duration: 0.08)
}

/// Emil Kowalski 物理按压反馈：
///   - 触摸瞬时按压比例 0.96
///   - 伴随触感微反馈 UIImpactFeedbackGenerator(style: .light)
struct Pressable: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.98
    var haptic: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(Motion.quick, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed && haptic {
                    Haptics.tap()
                }
            }
    }
}

/// 消息与组件插入动效：微位移 (4pt) + 快速淡入，杜绝大幅度晃动造成的廉价感
struct Appear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on ? 1.0 : 0.0)
            .offset(y: on || reduceMotion ? 0 : 4)
            .onAppear {
                withAnimation(Motion.fade) {
                    on = true
                }
            }
    }
}

extension View {
    func appearOnInsert() -> some View { modifier(Appear()) }
}

/// 静态工作提示：流式内容本身提供进度，不为指示点持续刷新界面。
struct TypingDots: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Palette.textFaint).frame(width: 4, height: 4)
            }
        }
        .accessibilityLabel("正在回复")
    }
}

struct LiveDot: View {
    var body: some View {
        Circle().fill(Palette.accentText).frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

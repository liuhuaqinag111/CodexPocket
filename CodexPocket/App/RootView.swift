import SwiftUI

/// 根视图。
///
/// 结构对齐 ChatGPT：**会话页永远是根**，会话列表是左侧抽屉。
/// 没打开会话时给一个空的会话页（顶部两个圆按钮 + 输入框），
/// 不是先看到一个列表页再点进去。
struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var store: AppCoordinator
    @GestureState(resetTransaction: Transaction(animation: Motion.base)) private var dragX: CGFloat = 0

    /// 根视图 `body` 重算的次数与累计毫秒。
    ///
    /// 「整个软件好卡」量的是**这一层**：`AppCoordinator` 转发子模型的
    /// `objectWillChange`，根视图每重算一次，抽屉、输入框、状态条、消息列表
    /// 全部跟着重算。`ChatView.bodyRuns` 只看得见其中一块。
    static var bodyRuns = 0
    static var bodyMs: Double = 0
    static var bodyMax: Double = 0

    static func record(_ t0: CFAbsoluteTime) {
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        Self.bodyMs += ms
        Self.bodyRuns += 1
        if ms > Self.bodyMax { Self.bodyMax = ms }
    }

    var body: some View {
        let t0 = CFAbsoluteTimeGetCurrent()
        let v = Group {
            if store.needsPairing { PairingView(isInitial: true) }
            else { content }
        }
        .sheet(isPresented: $store.showPairing) { PairingView(isInitial: false) }
        Self.record(t0)
        return v
    }

    var content: some View {
        GeometryReader { geometry in
        ZStack(alignment: .leading) {
            Palette.bg.ignoresSafeArea()

            // 会话页永远是根。
            chatRoot
                .simultaneousGesture(openGesture(width: geometry.size.width))

            // 列表全屏推入；手势和程序化切换共用同一个位移状态。
            if store.showDrawer || dragX > 0 {
                ThreadListView()
                    .offset(x: drawerOffset(width: geometry.size.width))
                    .simultaneousGesture(closeGesture(width: geometry.size.width))
                    .transition(Self.drawerInsertionTransition(isDragging: dragX > 0,
                                                         reduceMotion: reduceMotion))
                    .zIndex(1)
            }
        }
        }
        .animation(reduceMotion ? nil : Motion.base, value: store.showDrawer)
        // 打开抽屉就重新拉一次会话列表。
        // 以前列表只在 App 连上时拉一次，之后电脑端新建/删除/归档的会话
        // 手机上永远看不到（实测：对端建会话再删掉，列表计数全程不变）。
        .onChange(of: store.showDrawer) { open in
            if open {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                store.list.load()
            }
        }
        .overlay(alignment: .bottom) {
            if let b = (store.showDrawer ? store.banner ?? store.chat.banner : store.activeBanner) { banner(b) }
        }
        .animation(Motion.fade, value: store.activeBanner)
        // 通知链路的状态，测试靠它判定"发了没有 / 为什么没发"。
        .overlay(alignment: .topLeading) {
            Text("")
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityElement()
                .accessibilityIdentifier("notifyState")
                .accessibilityValue(store.notifyState)
        }
    }

    /// 冷启动就是**列表页**（跟 ChatGPT 一致），
    /// 不是一块只有一句灰字的空屏 —— 那看着就是半成品。
    @ViewBuilder
    private var chatRoot: some View {
        // 刚 thread/start 出来的会话还没进 threads 数组（服务端落盘有延迟），
        // 这时 current 是 nil。以前这里会退回列表页 —— 表现就是"新会话创建不了"：
        // 点了铅笔，列表晃一下又回来。只要有 id 就进会话页，内容随后补上。
        if store.list.currentID != nil {
            ChatView()
        } else {
            // 没有当前会话、列表也关着：给 ChatGPT 那种空会话页
            // （顶栏 + 中间一句话 + 底部输入框），别只剩一块黑屏。
            EmptyChatView()
        }
    }

    /// 从屏幕左缘往右拖 = 拉开列表。
    private func openGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .updating($dragX) { v, offset, transaction in
                guard !store.showDrawer, v.startLocation.x < 24,
                      v.translation.width > abs(v.translation.height) else { return }
                transaction.animation = nil
                offset = min(width, max(0, v.translation.width))
            }
            .onEnded { v in
                guard !store.showDrawer, v.startLocation.x < 24,
                      v.translation.width > abs(v.translation.height) else { return }
                if v.translation.width > 70 || v.predictedEndTranslation.width > 140 {
                    store.showDrawer = true
                }
            }
    }

    /// 从列表右缘左滑返回会话；只占 28pt 边缘，避开行内左滑操作。
    private func closeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .updating($dragX) { v, offset, transaction in
                guard store.showDrawer, v.startLocation.x > width - 28,
                      v.translation.width < -abs(v.translation.height) else { return }
                transaction.animation = nil
                offset = max(-width, min(0, v.translation.width))
            }
            .onEnded { v in
                guard store.showDrawer, v.startLocation.x > width - 28,
                      v.translation.width < -abs(v.translation.height) else { return }
                if v.translation.width < -70 || v.predictedEndTranslation.width < -140 {
                    store.showDrawer = false
                }
            }
    }

    private func drawerOffset(width: CGFloat) -> CGFloat {
        if store.showDrawer { return max(-width, min(0, dragX)) }
        return min(0, -width + max(0, dragX))
    }

    static func drawerInsertionTransition(isDragging: Bool,
                                          reduceMotion: Bool) -> AnyTransition {
        if !shouldAnimateDrawerInsertion(isDragging: isDragging) { return .identity }
        return reduceMotion ? .opacity : .move(edge: .leading)
    }

    static func shouldAnimateDrawerInsertion(isDragging: Bool) -> Bool {
        !isDragging
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(Palette.F.note)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Capsule().fill(Palette.surface))
            .padding(.bottom, 90)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .onTapGesture { store.clearBanner() }
    }
}

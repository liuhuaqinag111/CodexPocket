import SwiftUI
import UIKit
import UserNotifications

/// 通知点开 → 直接进那个会话。
///
/// 之前回合跑完 App 没有任何提示（用户："哪个会话回答完成了我都看不出来"）。
/// 现在后台跑完会推本地通知，点一下回到对应会话。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// 由 App 启动时注入，点通知时用来跳会话。
    @MainActor static weak var store: AppCoordinator? {
        didSet {
            guard let store, let id = pendingThreadID else { return }
            pendingThreadID = nil
            store.requestOpenThread(id)
        }
    }
    @MainActor private(set) static var pendingThreadID: String?

    @MainActor static func requestOpenThread(_ id: String) {
        guard !id.isEmpty else { return }
        if let store { store.requestOpenThread(id) }
        else { pendingThreadID = id }
    }

    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // 主线程卡顿探针（设置页和 chatState 探针读它的值）。
        FreezeWatchdog.start()
        // 后台任务 handler 必须在这里注册（返回之后就注册不上了）。
        BackgroundKeeper.shared.registerAtLaunch()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["threadId"] as? String
        Task { @MainActor in
            if let id { Self.requestOpenThread(id) }
            done()
        }
    }
}

@main
struct CodexPocketApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppCoordinator()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(store.chat)
                .tint(Palette.accentText)
                .onAppear {
                    AppDelegate.store = store
                    store.connect()
                    if store.settings.isConfigured { Notifier.request() }
                    // 音频会话要**提前**配好并挂上中断监听。
                    // 等到切后台才配，系统可能已经挂起进程，setActive 直接失败
                    // —— 表现就是"一切后台就断联"。
                    BackgroundKeeper.shared.prepare()
                    AppDelegate.store = store
                }
                // 通知点开：codexpocket://thread/<id> 直接进那个会话。
                .onOpenURL { url in
                    guard url.scheme == "codexpocket" else { return }
                    if url.host == "pair" {
                        let preview = { store.previewPairing(url.absoluteString, present: true) }
                        let scene = UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .first { $0.activationState == .foregroundActive }
                        let root = scene?.windows.first { $0.isKeyWindow }?.rootViewController
                        if root?.presentedViewController != nil {
                            root?.dismiss(animated: true, completion: preview)
                        } else { preview() }
                    } else if let id = AppDeepLink.threadID(url) {
                        AppDelegate.requestOpenThread(id)
                    }
                }
        }
        .onChange(of: phase) { p in
            switch p {
            case .active: store.enterForeground()
            case .background: store.enterBackground()
            default: break
            }
        }
    }
}

import SwiftUI

/// 设置：连接、后台、语音、状态、版本。
struct SettingsView: View {
    @EnvironmentObject var store: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showToken = false

    private var s: PreferencesModel { store.settings }

    @State private var update: UpdateCheck.Info?
    @State private var checking = false
    @State private var downloaded: URL?
    @State private var updateMsg = ""

    /// 「检查更新 / 立即升级」。
    ///
    /// 只能做到"帮你把包拉到手"这一步：这个包是**未签名**的，iOS 不认，
    /// 真正装上去还得靠 Sideloadly / AltStore / TrollStore。所以文案里
    /// 必须写清楚，别让人以为点了就能自动装完。
    @ViewBuilder
    private var updateRow: some View {
        if let u = update, u.isNewer {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LucideIcon("download")
                        .foregroundStyle(Palette.accentText)
                    Text("有新版本").font(Palette.F.note.weight(.semibold))
                }
                Text(u.build).font(Palette.F.caption).foregroundStyle(Palette.textSub)
                if !updateMsg.isEmpty {
                    Text(updateMsg).font(Palette.F.caption)
                        .foregroundStyle(Palette.textFaint)
                }
                HStack(spacing: 10) {
                    Button(downloaded == nil ? "下载安装包" : "重新下载") { runDownload(u) }
                        .font(Palette.F.note.weight(.semibold)).frame(minHeight: 44)
                    if let f = downloaded {
                        Button("去安装") { share(f) }
                            .font(Palette.F.note.weight(.semibold)).frame(minHeight: 44)
                    }
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack {
                Button(checking ? "检查中…" : "检查更新") { runCheck() }
                    .disabled(checking)
                Spacer(minLength: 0)
                if !updateMsg.isEmpty {
                    Text(updateMsg).font(Palette.F.caption)
                        .foregroundStyle(Palette.textFaint)
                }
            }
        }
    }

    /// 放锁是**显式**动作。
    ///
    /// 它会重启电脑端的手机 app-server：排队消息会丢、十几秒连不上。
    /// 所以不能自动做，只能用户自己按。
    /// 需要它的时候：桌面 Codex 弹「已在另一个应用中打开」。
    @ViewBuilder
    private var lockRow: some View {
        Button("释放电脑端会话锁") {
            updateMsg = "正在释放…"
            Task { @MainActor in updateMsg = await store.releaseWriterLocks() }
        }
        .font(Palette.F.note).frame(minHeight: 44)
        Text("手机打开过或发过消息的会话会占住电脑端的锁。"
             + "电脑上打不开某个会话时按这个。")
            .font(Palette.F.caption)
            .foregroundStyle(Palette.textFaint)
    }

    private func runCheck() {
        checking = true
        updateMsg = ""
        Task { @MainActor in
            let r = await UpdateCheck.fetch(s)
            checking = false
            update = r
            if let r {
                updateMsg = r.isNewer ? "" : "已是最新（服务端 \(r.build.prefix(10))）"
            } else {
                updateMsg = "连不上电脑，查不了"
            }
        }
    }

    private func runDownload(_ u: UpdateCheck.Info) {
        updateMsg = "下载中…"
        Task { @MainActor in
            let f = await UpdateCheck.download(u) { _ in }
            downloaded = f
            updateMsg = f == nil ? "下载失败" : "已存到「文件」→ 我的 iPhone → CodexPocket"
        }
    }

    private func share(_ f: URL) {
        let vc = UIActivityViewController(activityItems: [f], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        root.present(vc, animated: true)
    }

    /// `s` 是计算属性，拿不到 `$`，这里显式做绑定。
    private func bind(_ kp: ReferenceWritableKeyPath<PreferencesModel, String>) -> Binding<String> {
        Binding(get: { s[keyPath: kp] }, set: { s[keyPath: kp] = $0 })
    }

    private func bind(_ kp: ReferenceWritableKeyPath<PreferencesModel, Bool>) -> Binding<Bool> {
        Binding(get: { s[keyPath: kp] }, set: { s[keyPath: kp] = $0 })
    }

    /// 帧级日志开关。值存在 UserDefaults 里（`FrameLog.enabled` 直接读它），
    /// 所以这里不能走 PreferencesModel。
    private var debugFrames: Binding<Bool> {
        Binding(get: { FrameLog.enabled },
                set: { UserDefaults.standard.set($0, forKey: FrameLog.flagKey) })
    }

    @ViewBuilder
    private func header(_ t: String) -> some View {
        Text(t).font(Palette.F.caption.weight(.semibold)).foregroundStyle(Palette.textSub)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        LucideIcon(store.state.isReady ? "plug-zap" : "unplug", size: 28)
                            .foregroundStyle(store.state.isReady ? Palette.accentText : Palette.textSub)
                            .frame(width: 52, height: 52)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.state.label).font(.title3.weight(.semibold)).foregroundStyle(Palette.text)
                            Text("连接、偏好与运行状态")
                                .font(Palette.F.note).foregroundStyle(Palette.textSub)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Palette.bg)
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务器").font(Palette.F.caption).foregroundStyle(Palette.textSub)
                        TextField("域名", text: bind(\.host))
                            .font(Palette.F.body)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("settings.host")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("端口").font(Palette.F.caption).foregroundStyle(Palette.textSub)
                        TextField("443", text: bind(\.port))
                            .font(Palette.F.body)
                            .keyboardType(.numberPad)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("令牌").foregroundStyle(Palette.textSub)
                            Spacer()
                            Button(showToken ? "隐藏" : "显示") { showToken.toggle() }
                                .font(Palette.F.caption).frame(minWidth: 44, minHeight: 44)
                        }
                        if showToken {
                            TextField("token", text: bind(\.token), axis: .vertical)
                                .font(.subheadline.monospaced())
                                .lineLimit(1...3)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .accessibilityIdentifier("settings.token")
                        } else {
                            Text(s.token.isEmpty ? "未设置"
                                 : String(s.token.prefix(10)) + "…")
                                .font(.subheadline.monospaced())
                                .foregroundStyle(Palette.textFaint)
                        }
                    }
                    Button { s.host = ""; s.port = "443" } label: {
                        LucideLabel("填入服务器地址", "globe").frame(minHeight: 44)
                    }
                } header: {
                    header("连接")
                } footer: {
                    Text("使用电脑端提供的连接地址和令牌。")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("默认工作目录").font(Palette.F.caption).foregroundStyle(Palette.textSub)
                        TextField("~", text: bind(\.defaultCwd))
                            .font(Palette.F.body.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("settings.cwd")
                    }
                } header: {
                    header("新会话")
                } footer: {
                    Text("新会话的默认工作目录，留空使用家目录。")
                }

                Section {
                    Toggle("切后台保持连接", isOn: bind(\.keepAlive))
                        .accessibilityIdentifier("settings.keepAlive")
                } header: {
                    header("后台")
                } footer: {
                    Text("用一段无声音频让 App 不被挂起，费一点电。")
                }

                Section("状态") {
                    LabeledContent("App 版本") {
                        Text(Build.stamp).accessibilityIdentifier("settings.build")
                    }
                    LabeledContent("连接") {
                        HStack(spacing: 6) {
                            LucideIcon(store.state.isReady ? "circle-check" : "circle-alert", size: 16)
                                .foregroundStyle(store.state.isReady ? Palette.success : Palette.danger)
                            Text(store.state.label)
                        }
                    }
                    // 链路质量：这次连上多久了、累计掉线几次。
                    // 用户报"一直断链"时，这两个数字就是证据。
                    if let t = store.rpc.connectedSince {
                        LabeledContent("本次连接") {
                            Text(AppCoordinator.duration(since: t))
                        }
                    }
                    LabeledContent("累计掉线") {
                        Text("\(store.rpc.drops) 次")
                            .foregroundStyle(store.rpc.drops > 20 ? Palette.danger : Palette.text)
                    }
                    LabeledContent("会话数") { Text("\(store.list.threads.count)") }
                }

                Section("维护") {
                    updateRow
                    lockRow
                    Button { store.connect() } label: {
                        LucideLabel("重新连接", "plug-zap").frame(minHeight: 44)
                    }
                    Button { store.list.load() } label: {
                        LucideLabel("刷新会话列表", "refresh-cw").frame(minHeight: 44)
                    }
                        .disabled(!store.state.isReady)
                    Button { store.cache.clear(); store.banner = "缓存已清" } label: {
                        LucideLabel("清空本地缓存", "database").frame(minHeight: 44)
                    }
                }

                Section {
                    Toggle("帧级日志", isOn: debugFrames)
                        .accessibilityIdentifier("settings.frames")
                    Button("上传到电脑") {
                        Task { @MainActor in
                            let ok = await FrameLog.upload(store.settings) != nil
                            store.banner = ok ? "日志已传到 ~/.codex/phone/frames.log"
                                              : "上传失败（没连上电脑端？）"
                        }
                    }
                    .disabled(!FrameLog.enabled)
                    Button("清空日志", role: .destructive) { FrameLog.clear() }
                        .disabled(!FrameLog.enabled)
                } header: {
                    header("诊断")
                } footer: {
                    Text("排查「看不见回复」用。FRAME = 事件到了；GATE = 被放行还是被丢、为什么；RENDER = 真的画上屏了。"
                         + "开着会拖慢流式渲染，平时关掉。")
                }

                Section("说明") {
                    Text("手机通过隧道连到电脑上的 Codex 服务，令牌鉴权，只读你自己的会话数据。")
                        .font(Palette.F.caption)
                        .foregroundStyle(Palette.textSub)
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 52)
            .scrollContentBackground(.hidden)
            .background(Palette.bg)
            .tint(Palette.accentText)
            .toolbarBackground(Palette.bg, for: .navigationBar)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if store.rpc.url != s.url || store.rpc.token != s.token { store.connect() }
                        dismiss()
                    }
                    .font(Palette.F.note.weight(.semibold)).frame(minHeight: 44)
                }
            }
        }
        .onDisappear {
            if store.rpc.url != s.url || store.rpc.token != s.token { store.connect() }
        }
    }
}

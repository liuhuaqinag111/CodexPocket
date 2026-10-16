import SwiftUI
import UIKit

/// 轻量多行输入框，操作围绕正文排布，周围保持透明。
struct Composer: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var store: AppCoordinator
    @FocusState private var focused: Bool
    private var c: ComposerModel { store.composer }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !c.images.isEmpty { pending }
            uploadNote
            voiceNote
            if c.unsentCount > 0 || c.hasFailedOutgoing { outboxNote }
            SuggestionBar()
            cardInput
        }
        .padding(.horizontal, UI.gutter)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Palette.bg)
    }
}

extension Composer {
    /// 单行起步，多行自然增高；附件、听写、发送都在拇指可及的位置。
    private var cardInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("发消息，继续你的工作…", text: Binding(get: { c.text }, set: { c.text = $0 }),
                      prompt: Text("发消息，继续你的工作…").foregroundColor(Palette.placeholder), axis: .vertical)
                .font(Palette.F.composer)
                .foregroundStyle(Palette.text)
                .lineLimit(1...5)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 16).padding(.top, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("composer.field")
            HStack(spacing: 4) {
                attachButton
                if running {
                    Text(c.action == .queue ? "本轮结束后发送" : "继续补充指令")
                        .font(Palette.F.caption).foregroundStyle(Palette.textSub)
                }
                Spacer(minLength: 8)
                mic
                sendOrStop
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
        .background(Palette.inputBg, in: RoundedRectangle(cornerRadius: Palette.R.composer, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Palette.R.composer, style: .continuous)
                .strokeBorder(focused ? Palette.accent.opacity(0.6) : Palette.separatorFaint, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(Motion.quick, value: focused)
    }

    /// 左下角加号圆钮 (#2C2C30)
    private var attachButton: some View {
        Menu {
            Button { pick(.photoLibrary) } label: { LucideLabel("相册", "photo") }
            Button { pick(.camera) } label: { LucideLabel("拍照", "camera") }
            Button { c.pasteImage() } label: { LucideLabel("粘贴图片", "doc.on.clipboard") }
            if running {
                Divider()
                Button {
                    c.sendMode = (c.sendMode == .auto ? .queue : .auto)
                } label: {
                    LucideLabel(c.sendMode == .queue ? "切换为插话发送" : "切换为排队发送", c.sendMode == .queue ? "bolt" : "clock")
                }
                .accessibilityIdentifier("composer.mode")
            }
        } label: {
            LucideIcon("plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.plusIcon)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("添加附件")
        .accessibilityIdentifier("composer.attach")
    }

    /// 麦克风
    private var mic: some View {
        Button {
            store.voice.toggle()
        } label: {
            LucideIcon(store.voice.listening ? "waveform" : "mic")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(store.voice.listening ? Palette.accentText : Palette.micIcon)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(store.voice.listening ? "结束听写" : "语音输入")
        .accessibilityIdentifier("composer.mic")
    }

    /// 当前有没有回合在跑。
    ///
    /// 不能直接读 `c.chat` —— `ComposerModel.chat` 是 `private`。
    /// 走 `action` 这一层：它是 `.stop` / `.steer` / `.queue` 就说明在跑。
    private var running: Bool {
        switch c.action {
        case .stop, .steer, .queue: return true
        case .send, .idle: return false
        }
    }

    /// 右下角发送 / 停止按钮 (白底纯圆)
    private var sendOrStop: some View {
        Button { submit() } label: {
            LucideIcon(sendIcon, size: 20)
                .foregroundStyle(c.action == .idle ? Palette.textFaint : Palette.iconInverted)
                .frame(width: 44, height: 44)
                .background(c.action == .idle ? Palette.surface : Palette.buttonBg,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .disabled(c.action == .idle)
        .animation(Motion.quick, value: c.action)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(sendLabel)
        .accessibilityIdentifier("composer.send")
        .disabled(c.action == .idle)
    }

    private var sendIcon: String {
        switch c.action {
        case .stop: return "square"
        case .queue: return "clock-arrow-up"
        case .steer: return "corner-down-right"
        case .send, .idle: return "arrow-up"
        }
    }

    private var sendLabel: String {
        switch c.action {
        case .stop: return "停止回复"
        case .queue: return "排队发送"
        case .steer: return "插话发送"
        case .send, .idle: return "发送消息"
        }
    }

    private func submit() {
        c.submit()
        focused = false
    }

    @ViewBuilder
    private var voiceNote: some View {
        if let message = store.voice.error {
            HStack(spacing: 8) {
                LucideIcon("circle-alert", size: 16)
                Text(message).font(Palette.F.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if store.voice.denied {
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(Palette.F.caption)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("composer.voiceSettings")
                }
            }
            .foregroundStyle(Palette.danger)
            .accessibilityIdentifier("composer.voiceError")
        }
    }

    private func pick(_ source: UIImagePickerController.SourceType) {
        PhotoPicker.present(source) { path in
            if let path { c.upload(path) }
        }
    }

    @ViewBuilder
    private var uploadNote: some View {
        if c.uploading > 0 {
            Text("图片上传中…")
                .font(Palette.F.caption)
                .foregroundStyle(Palette.textFaint)
        } else if let e = c.uploadError {
            Text(e)
                .font(Palette.F.caption)
                .foregroundStyle(Palette.warning)
        }
    }

    private var pending: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(c.images.enumerated()), id: \.offset) { i, p in
                    ImageThumb(url: p)
                        .frame(width: 54, height: 54)
                        .overlay(alignment: .bottom) {
                            if c.uploading == 0, i < c.remotePaths.count, c.remotePaths[i].isEmpty {
                                Button("重试") { c.retryUpload(at: i) }
                                    .font(Palette.F.caption)
                                    .foregroundStyle(Palette.text)
                                    .padding(3)
                                    .background(Palette.bg)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button { c.removeImage(at: i) } label: {
                                LucideIcon("xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.text, Palette.bg)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("移除附件 \(i + 1)")
                        }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var outboxNote: some View {
        HStack {
            if c.unsentCount > 0 { Text("本会话 \(c.unsentCount) 条消息保存在本机") }
            if c.hasFailedOutgoing {
                Text("有消息未发送")
                Button { c.retryOutbox() } label: {
                    Text("重试").frame(minWidth: 44, minHeight: 44)
                }
                    .accessibilityIdentifier("composer.retryOutbox")
                Button { c.clearFailedOutgoing() } label: {
                    Text("清除").frame(minWidth: 44, minHeight: 44)
                }
                    .accessibilityIdentifier("composer.clearFailedOutbox")
            }
        }
        .font(Palette.F.caption)
        .foregroundStyle(Palette.textFaint)
    }
}

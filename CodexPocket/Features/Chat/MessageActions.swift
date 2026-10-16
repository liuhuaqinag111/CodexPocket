import SwiftUI
import AVFoundation

/// 消息行操作。复制由系统选字菜单负责；当前界面不展示整行操作栏。
struct MessageActions: View {
    let text: String
    /// 重新生成：用这条回复之前的那句用户消息再跑一轮。
    var onRegenerate: (() -> Void)?

    @State private var speaking = false
    private static let speaker = Speaker()

    var body: some View {
        HStack(spacing: 0) {
            action(speaking ? "stop.fill" : "speaker.wave.2",
                   id: "act.speak", tint: speaking ? Palette.accentText : Palette.iconFaint) {
                speaking.toggle()
                Self.speaker.toggle(text) { speaking = false }
            }

            if let onRegenerate {
                action("arrow.clockwise", id: "act.regen", tint: Palette.iconFaint) {
                    onRegenerate()
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func action(_ system: String, id: String, tint: Color,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            LucideIcon(system)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .accessibilityIdentifier(id)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(id == "act.regen" ? "重新生成" : (speaking ? "停止朗读" : "朗读回复"))
    }
}

/// 朗读。用系统 TTS，纯本地，不依赖上游。
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var done: (() -> Void)?

    func toggle(_ text: String, done: @escaping () -> Void) {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
            self.done = nil
            done()
            return
        }
        guard !text.isEmpty else { return }
        self.done = done
        synth.delegate = self
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        synth.speak(u)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer,
                           didFinish u: AVSpeechUtterance) {
        done?()
        done = nil
    }
}

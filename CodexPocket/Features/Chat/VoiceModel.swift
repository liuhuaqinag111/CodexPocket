import Foundation
import Combine
import Speech
import AVFoundation

/// 本地听写：用系统 Speech 框架，边说边出字，直接并进输入框。
@MainActor
final class VoiceModel: ObservableObject {
    @Published var listening = false
    @Published var denied = false
    @Published var error: String?

    /// 识别结果回调（全量文本）。
    var onText: ((String) -> Void)?
    var onStarted: (() -> Void)?
    var onStopped: (() -> Void)?
    private var generation = 0
    private var permissionPending = false
    private var tapInstalled = false
    private let authorizeMicrophone: (@escaping (Bool) -> Void) -> Void

    private let list: ThreadListModel
    private let authorizeSpeech: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    init(list: ThreadListModel,
         authorizeMicrophone: @escaping (@escaping (Bool) -> Void) -> Void
            = { AVAudioSession.sharedInstance().requestRecordPermission($0) },
         authorizeSpeech: @escaping (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
            = { SFSpeechRecognizer.requestAuthorization($0) }) {
        self.list = list
        self.authorizeSpeech = authorizeSpeech
        self.authorizeMicrophone = authorizeMicrophone
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    // MARK: - 听写

    func toggle() { listening || permissionPending ? stop() : start() }

    func start() {
        guard !listening, !permissionPending else { return }
        permissionPending = true
        denied = false
        error = nil
        generation += 1
        let current = generation
        let threadID = list.currentID
        onStarted?()
        authorizeSpeech { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard self.generation == current else { return }
                guard self.list.currentID == threadID else { self.stop(); return }
                guard status == .authorized else {
                    self.denied = true
                    self.error = "未允许语音识别，请在系统设置中开启权限"
                    self.stop(); return
                }
                self.authorizeMicrophone { ok in
                    Task { @MainActor in
                        guard self.generation == current else { return }
                        guard self.list.currentID == threadID else { self.stop(); return }
                        self.permissionPending = false
                        guard ok else {
                            self.denied = true
                            self.error = "未允许麦克风访问，请在系统设置中开启权限"
                            self.stop(); return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else {
            error = "语音识别暂不可用"
            stop()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
                req.append(buf)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()
            listening = true

            let current = generation
            task = recognizer.recognitionTask(with: req) { [weak self] result, failure in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    if let result { self.onText?(result.bestTranscription.formattedString) }
                    if result?.isFinal == true || failure != nil { self.stop() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        let hadAudio = listening || tapInstalled
        generation += 1
        permissionPending = false
        onStopped?()
        guard hadAudio else { return }
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false,
                                                      options: [.notifyOthersOnDeactivation])
    }

    func stopDictationIfNeeded() {
        if listening || permissionPending { stop() }
    }
}

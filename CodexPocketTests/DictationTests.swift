import XCTest
import Speech
@testable import CodexPocket

@MainActor
final class DictationTests: XCTestCase {
    func testSendingEndsDictationAndIgnoresLateTranscript() {
        let wire = RecordingTransport()
        wire.deferResponse = true
        let store = AppCoordinator(transport: wire)
        store.list.currentID = "voice-a"
        store.composer.text = "请查 "
        store.voice.onStarted?()
        store.voice.listening = true
        store.voice.onText?("北京天气")
        store.composer.submit()
        store.voice.onText?("北京天气和上海天气")
        XCTAssertEqual(store.composer.text, "")
        XCTAssertFalse(store.voice.listening)
        XCTAssertNil(store.composer.dictationBase)
        store.composer.outbox = []
        store.composer.draftTimer?.invalidate()
    }

    func testDeniedSpeechPermissionEndsDictationBase() async {
        let store = AppCoordinator(transport: RecordingTransport())
        var stopped = 0
        let settled = expectation(description: "speech permission rejected")
        let voice = VoiceModel(list: store.list, authorizeSpeech: { $0(.denied) })
        voice.onStopped = { stopped += 1; settled.fulfill() }
        voice.start()
        await fulfillment(of: [settled], timeout: 1)
        XCTAssertEqual(stopped, 1)
        XCTAssertTrue(voice.denied)
        XCTAssertEqual(voice.error, "未允许语音识别，请在系统设置中开启权限")
    }

    func testDeniedMicrophonePermissionIsVisibleWithoutAudioHardware() async {
        let store = AppCoordinator(transport: RecordingTransport())
        let voice = VoiceModel(list: store.list,
            authorizeMicrophone: { $0(false) }, authorizeSpeech: { $0(.authorized) })
        let settled = expectation(description: "microphone permission rejected")
        voice.onStopped = { settled.fulfill() }
        voice.start()
        await fulfillment(of: [settled], timeout: 1)
        XCTAssertTrue(voice.denied)
        XCTAssertEqual(voice.error, "未允许麦克风访问，请在系统设置中开启权限")
    }
    func testRepeatedStartAndStoppedAuthorizationCannotRestartDictation() async {
        let store = AppCoordinator(transport: RecordingTransport())
        var requests = 0
        var callbacks: [(SFSpeechRecognizerAuthorizationStatus) -> Void] = []
        let voice = VoiceModel(list: store.list,
            authorizeSpeech: { requests += 1; callbacks.append($0) })
        voice.start(); voice.start()
        XCTAssertEqual(requests, 1)
        voice.stop()
        voice.start()
        XCTAssertEqual(requests, 2)
        callbacks[0](.denied)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(voice.denied)
        callbacks[1](.denied)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(voice.denied)
        voice.stop()
    }

    func testEachDictationStartsWithTheCurrentDraft() {
        let store = AppCoordinator(transport: RecordingTransport())
        store.composer.text = "前缀 "
        store.voice.onStarted?()
        store.voice.onText?("第一段")
        store.voice.onStopped?()
        store.voice.onStarted?()
        store.voice.onText?(" 第二段")
        XCTAssertEqual(store.composer.text, "前缀 第一段 第二段")
        store.composer.draftTimer?.invalidate()
    }
    func testPartialTranscriptsReplaceRecognizedTextInsteadOfAppendingIt() {
        let store = AppCoordinator(transport: RecordingTransport())
        store.list.currentID = "voice-a"
        store.composer.text = "请查 "
        store.voice.onStarted?()
        store.voice.onText?("北京")
        store.voice.onText?("北京天气")
        XCTAssertEqual(store.composer.text, "请查 北京天气")
        store.composer.draftTimer?.invalidate()
    }

    func testLateTranscriptCannotChangeAnotherThreadsDraft() {
        let store = AppCoordinator(transport: RecordingTransport())
        store.list.currentID = "voice-a"
        store.composer.text = "A "
        store.voice.onStarted?()
        store.voice.onText?("第一句")
        store.list.currentID = "voice-b"
        store.composer.text = "B 的草稿"
        store.voice.onText?("第一句补充")
        XCTAssertEqual(store.composer.text, "B 的草稿")
        store.composer.draftTimer?.invalidate()
    }
}

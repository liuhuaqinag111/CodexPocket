import XCTest
import UIKit
@testable import CodexPocket

/// 输入区里的待发图片。
///
/// 两个 bug：
///   1. `submit()` 发出去的是**手机本地路径**，电脑上不存在 —— 带图必失败。
///   2. `canSend` 只要 `images` 非空就算能发，于是"图还在上传"时按发送，
///      发出去的是个空路径。
final class ComposerImageTests: XCTestCase {
    @MainActor
    func testPhotoSaveOnlyReportsSuccessAfterCallback() async {
        var written: Data?
        var complete: ((Error?) -> Void)?
        let saver = PhotoSaver(writer: { data, done in written = data; complete = done })
        let original = Data([0, 1, 2, 255, 17])
        saver.save(original)
        XCTAssertEqual(written, original, "必须把原始字节交给相册写入器")
        XCTAssertTrue(saver.saving)
        XCTAssertFalse(saver.saved)
        complete?(nil)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(saver.saving)
        XCTAssertTrue(saver.saved)
        XCTAssertFalse(saver.failed)
    }

    @MainActor
    func testPhotoSaveErrorDoesNotShowSaved() async {
        let saver = PhotoSaver(writer: { _, done in done(NSError(domain: "test", code: 1)) })
        saver.save(Data([1, 2, 3]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(saver.saving)
        XCTAssertFalse(saver.saved)
        XCTAssertTrue(saver.failed)
    }
    @MainActor
    func testPhotoSaveCanRetrySameOriginalBytesAfterFailure() async {
        var written: [Data] = []
        let saver = PhotoSaver(writer: { data, done in
            written.append(data)
            done(written.count == 1 ? RepositoryError(message: "denied") : nil)
        })
        let original = Data([255, 7, 0, 3])
        saver.save(original)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(saver.failed)
        saver.save(original)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(written, [original, original])
        XCTAssertTrue(saver.saved)
        XCTAssertFalse(saver.failed)
    }

    @MainActor
    func testReconnectKeepsSecondMessageUntilFirstHasFinishedPreparing() async {
        let transport = RecordingTransport()
        transport.deferResponse = true
        let store = AppCoordinator(transport: transport)
        defer { store.composer.outbox = [] }
        store.list.currentID = "outbox-test"
        store.composer.outbox = [
            .init(threadId: "outbox-test", text: "one", images: []),
            .init(threadId: "outbox-test", text: "two", images: ["/remote/two"])]
        store.composer.flushOutbox()
        XCTAssertEqual(store.composer.outbox.map(\.text), ["one", "two"])
        XCTAssertEqual(store.composer.outbox.last?.images, ["/remote/two"])
        store.composer.flushOutbox()
        XCTAssertEqual(store.chat.items.filter { if case .user = $0 { return true }; return false }.count, 1)
        store.chat.close()
    }

    @MainActor
    func testOfflineMessageRetainsThreadAndImages() {
        let store = AppCoordinator()
        store.composer.outbox = []
        defer { store.composer.outbox = [] }
        store.list.currentID = "synthetic-A"
        store.composer.text = "photo"
        store.composer.images = ["/synthetic/a"]
        store.composer.remotePaths = ["/remote/a"]
        store.composer.submit()
        store.list.currentID = "synthetic-B"
        store.composer.flushOutbox()
        XCTAssertEqual(store.composer.outbox.count, 1)
        XCTAssertEqual(store.composer.outbox.first?.threadId, "synthetic-A")
        XCTAssertEqual(store.composer.outbox.first?.images, ["/remote/a"])
    }

    @MainActor
    func testSwitchSavesDraftToOriginalThread() throws {
        let store = AppCoordinator()
        let suite = "ComposerTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        store.list.currentID = "A"
        let composer = ComposerModel(repository: store.inputRepository, list: store.list, chat: store.chat,
                                     settings: store.settings, defaults: defaults)
        store.list.currentID = "B"
        composer.loadDraft()
        let bKey = composer.draftKey
        defaults.set("B draft", forKey: bKey)
        store.list.currentID = "A"
        composer.loadDraft()
        let aKey = composer.draftKey
        composer.text = "A draft"
        composer.images = ["/synthetic/a"]
        composer.remotePaths = ["/remote/a"]
        store.list.currentID = "B"
        composer.loadDraft()
        XCTAssertEqual(composer.text, "B draft")
        XCTAssertEqual(defaults.string(forKey: aKey), "A draft")
        XCTAssertTrue(composer.images.isEmpty)
        store.list.currentID = "A"
        composer.loadDraft()
        XCTAssertEqual(composer.text, "A draft")
        XCTAssertEqual(composer.remotePaths, ["/remote/a"])
    }

    @MainActor
    func testCannotSendWithOnlySomeImagesReady() {
        let composer = AppCoordinator().composer
        composer.images = ["a", "b"]
        composer.remotePaths = ["/tmp/a", ""]
        XCTAssertFalse(composer.canSend)
    }

    @MainActor
    func testSubmitWithoutThreadPreservesInput() {
        let store = AppCoordinator()
        store.list.currentID = nil
        store.composer.text = "keep me"
        store.composer.submit()
        XCTAssertEqual(store.composer.text, "keep me")
        XCTAssertTrue(store.composer.outbox.isEmpty)
    }

    @MainActor
    private func make() -> AppCoordinator { AppCoordinator() }

    /// 图片还没传完（remotePaths 里是空串）时不能发送。
    @MainActor
    func testCannotSendWhileImageHasNoRemotePath() {
        let store = make()
        store.composer.text = ""
        store.composer.images = ["/var/mobile/tmp/a.jpg"]
        store.composer.remotePaths = [""]
        XCTAssertFalse(store.composer.canSend, "图还没传上去就能发，会发出空路径")
    }

    /// 传完了（有电脑端路径）就能发。
    @MainActor
    func testCanSendOnceRemotePathIsReady() {
        let store = make()
        store.composer.text = ""
        store.composer.images = ["/var/mobile/tmp/a.jpg"]
        store.composer.remotePaths = ["/tmp/codex-pocket/a.jpg"]
        XCTAssertTrue(store.composer.canSend)
    }

    /// 上传中（uploading > 0）不让发。
    @MainActor
    func testCannotSendWhileUploading() {
        let store = make()
        store.composer.images = ["/var/mobile/tmp/a.jpg"]
        store.composer.remotePaths = ["/tmp/codex-pocket/a.jpg"]
        store.composer.uploading = 1
        XCTAssertFalse(store.composer.canSend, "上传中就能发，会发到半截")
    }

    /// 只有文字、没有图：照常能发。
    @MainActor
    func testTextOnlyStillSends() {
        let store = make()
        store.composer.text = "你好"
        XCTAssertTrue(store.composer.canSend)
    }

    /// 摘掉第 i 张图时，本地路径和电脑端路径必须一起摘，
    /// 否则两边错位 —— 删掉 A 结果发出去的是 B 的路径。
    @MainActor
    func testRemoveImageKeepsBothArraysInSync() {
        let store = make()
        store.composer.images = ["/a.jpg", "/b.jpg"]
        store.composer.remotePaths = ["/m/a.jpg", "/m/b.jpg"]
        store.composer.removeImage(at: 0)
        XCTAssertEqual(store.composer.images, ["/b.jpg"])
        XCTAssertEqual(store.composer.remotePaths, ["/m/b.jpg"], "两边错位了")
    }
}

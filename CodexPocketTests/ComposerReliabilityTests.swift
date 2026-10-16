import XCTest
@testable import CodexPocket

@MainActor
final class ComposerReliabilityTests: XCTestCase {
    func testUploadRetryNeverMovesAnInFlightImageToNewServer() async throws {
        let store = AppCoordinator(transport: RecordingTransport()), oldHost = PreferencesModel().host
        defer { store.settings.host = oldHost }
        store.settings.host = "wss://a.invalid/ws"
        let composer = ComposerModel(repository: store.inputRepository, list: store.list,
            chat: store.chat, settings: store.settings)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var waiter: CheckedContinuation<String, Error>?
        var urls: [URL] = []
        composer.uploadMedia = { _, url in
            urls.append(url)
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }
        composer.upload(file.path)
        for _ in 0..<50 where waiter == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let pending = try XCTUnwrap(waiter)
        store.settings.host = "wss://b.invalid/ws"; composer.loadDraft()
        pending.resume(throwing: RepositoryError(message: "offline"))
        for _ in 0..<100 where !composer.uploads.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(urls.map(\.host), ["a.invalid"])
        XCTAssertTrue(composer.uploads.isEmpty)
    }
    func testUploadStartedOnAIsCancelledBeforePostingAfterSwitchToB() async throws {
        let store = AppCoordinator(transport: RecordingTransport()), oldHost = PreferencesModel().host
        defer { store.settings.host = oldHost }
        store.settings.host = "wss://a.invalid/ws"
        let composer = ComposerModel(repository: store.inputRepository, list: store.list,
            chat: store.chat, settings: store.settings)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var urls: [URL] = []
        composer.uploadMedia = { _, url in urls.append(url); return "/remote/image" }
        composer.upload(file.path)
        store.settings.host = "wss://b.invalid/ws"
        composer.loadDraft()
        for _ in 0..<50 where !composer.uploads.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(urls.isEmpty)
        XCTAssertTrue(composer.uploads.isEmpty)
        store.settings.host = "wss://a.invalid/ws"; composer.loadDraft()
        XCTAssertEqual(composer.images, [file.path])
        XCTAssertEqual(composer.remotePaths, [""])
    }
    func testLegacyDraftMigratesOnlyToFirstServerAndNewDraftsStayIsolated() throws {
        let store = AppCoordinator(transport: RecordingTransport())
        let oldHost = store.settings.host, suite = "DraftNamespace." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); store.settings.host = oldHost }
        store.settings.host = "wss://a.invalid/ws"; store.list.currentID = "same-id"
        defaults.set("legacy text", forKey: "draft.same-id")
        let composer = ComposerModel(repository: store.inputRepository, list: store.list, chat: store.chat,
            settings: store.settings, defaults: defaults)
        composer.loadDraft()
        XCTAssertEqual(composer.text, "legacy text")
        composer.text = "A changed"
        store.settings.host = "wss://b.invalid/ws"; composer.loadDraft()
        XCTAssertTrue(composer.text.isEmpty)
        composer.text = "B draft"
        store.settings.host = "wss://a.invalid/ws"; composer.loadDraft()
        XCTAssertEqual(composer.text, "A changed")
        store.settings.host = "wss://b.invalid/ws"; composer.loadDraft()
        XCTAssertEqual(composer.text, "B draft")
        composer.draftTimer?.invalidate()
    }
    func testOnlineSubmissionPersistsBeforeDraftIsCleared() throws {
        let rpc = RecordingTransport(); rpc.deferResponse = true
        let store = AppCoordinator(transport: rpc)
        let suite = "ComposerOnline." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); store.chat.close() }
        store.list.currentID = "online"
        let composer = ComposerModel(repository: store.inputRepository, list: store.list, chat: store.chat,
            settings: store.settings, defaults: defaults)
        composer.text = "online retained"
        composer.submit()
        XCTAssertTrue(composer.text.isEmpty)
        XCTAssertEqual(composer.outbox.first?.text, "online retained")
        XCTAssertEqual(composer.outbox.first?.state, .awaitingAcknowledgement)
        let restored = ComposerModel(repository: store.inputRepository, list: store.list, chat: store.chat,
            settings: store.settings, defaults: defaults)
        XCTAssertEqual(restored.outbox.first?.localID, composer.outbox.first?.localID)
    }
    func testOutboxPersistsUntilExplicitAcknowledgementAndIsolatesServers() throws {
        let rpc = RecordingTransport(); rpc.deferResponse = true
        let store = AppCoordinator(transport: rpc)
        let oldHost = store.settings.host
        let suite = "ComposerReliability." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); store.settings.host = oldHost; store.chat.close() }
        store.settings.host = "wss://server-a.invalid/ws"
        store.list.currentID = "synthetic-outbox"
        func make() -> ComposerModel {
            ComposerModel(repository: store.inputRepository, list: store.list, chat: store.chat,
                settings: store.settings, defaults: defaults)
        }
        let composer = make()
        composer.outbox = [.init(threadId: "synthetic-outbox", text: "keep", images: ["/remote/image"])]
        let localID = try XCTUnwrap(composer.outbox.first?.localID)
        composer.flushOutbox()
        XCTAssertEqual(composer.outbox.first?.localID, localID)
        XCTAssertEqual(make().outbox.first?.localID, localID)
        composer.submissionResolved(localID, accepted: false)
        composer.flushOutbox()
        XCTAssertEqual(composer.outbox.first?.state, .failed)
        XCTAssertEqual(make().outbox.first?.state, .failed)
        store.settings.host = "wss://server-b.invalid/ws"
        composer.flushOutbox()
        XCTAssertTrue(composer.outbox.isEmpty)
        store.settings.host = "wss://server-a.invalid/ws"
        composer.flushOutbox()
        XCTAssertEqual(composer.outbox.first?.localID, localID)
        composer.submissionResolved(localID, accepted: true)
        XCTAssertTrue(composer.outbox.isEmpty)
        XCTAssertTrue(make().outbox.isEmpty)
    }

    func testFailedImageStaysInComposerAndRemovalPreservesOriginal() throws {
        let store = AppCoordinator(transport: RecordingTransport())
        let composer = store.composer
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("original".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        composer.images = [file.path]; composer.remotePaths = [""]; composer.uploading = 1
        let id = UUID(); composer.uploads[id] = (composer.draftKey, file.path)
        composer.finishUpload(id, remote: nil, error: "offline")
        XCTAssertEqual(composer.images, [file.path])
        XCTAssertFalse(composer.canSend)
        XCTAssertEqual(composer.uploadError, "offline")
        composer.removeImage(at: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

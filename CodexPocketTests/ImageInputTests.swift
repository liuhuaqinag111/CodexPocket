import XCTest
import UIKit
@testable import CodexPocket

/// 带图片发送。
///
/// 用户报的："为什么带图片发送的时候发送不成功"。
/// 根因（对着真实 app-server 实测）：App 发的是
/// `{"type":"image","path":"<手机本地路径>"}`，而服务端的 UserInput
/// 只认 `text`/`image`/`localImage`/`audio`/`localAudio`/`skill`/`mention`，
/// 其中 `image` 的两个变体是 `url` 和 `fileId` —— 配 `path` 会直接回
/// `Invalid request: data did not match any variant of untagged enum
/// ImageReference`，整个回合都不执行。
/// 而且那个 path 是**手机**的临时目录，电脑上根本不存在。
@MainActor
final class ImageInputTests: XCTestCase {
    func testWindowsImageSourcesUseTheComputerBridge() {
        let drive = #"C:\Pictures\sample.png"#
        XCTAssertEqual(ComputerPath.imageSource(drive), "C:/Pictures/sample.png")
        XCTAssertTrue(ComputerPath.isRemoteImage(drive))
        XCTAssertEqual(ComputerPath.imageSource("file:///C:/Pictures/a%20b.png"), "C:/Pictures/a b.png")
        XCTAssertTrue(ComputerPath.isRemoteImage("file:///C:/Pictures/sample.png"))
        XCTAssertEqual(ComputerPath.imageSource("file://server/share/sample.png"), "//server/share/sample.png")
        XCTAssertTrue(ComputerPath.isRemoteImage(#"\\server\share\sample.png"#))
    }

    func testPhoneImagesAndInlineDataStayLocal() {
        XCTAssertFalse(ComputerPath.isRemoteImage("/var/mobile/tmp/sample.png"))
        XCTAssertFalse(ComputerPath.isRemoteImage(NSHomeDirectory() + "/tmp/sample.png"))
        XCTAssertFalse(ComputerPath.isRemoteImage("data:image/png;base64,aGVsbG8/"))
        XCTAssertEqual(ComputerPath.imageSource("data:image/png;base64,aGVsbG8/"),
                       "data:image/png;base64,aGVsbG8/")
        XCTAssertTrue(ComputerPath.isRemoteImage("/var/mobile-other/sample.png"))
    }
    func testFullImageFailureBlocksSaveAndRetryLoadsOriginalBytes() async throws {
        let bytes = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 8))
            .image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4096, height: 8)) }
            .pngData())
        var attempt = 0
        let loader = FullImageLoader(reader: { _ in
            attempt += 1
            if attempt == 1 { throw RepositoryError(message: "offline") }
            return bytes
        })
        let url = URL(fileURLWithPath: "/synthetic/original.png")
        await loader.load(from: url)
        XCTAssertTrue(loader.failed)
        XCTAssertFalse(loader.canSave)
        XCTAssertNil(loader.originalData)
        await loader.load(from: url)
        XCTAssertFalse(loader.failed)
        XCTAssertTrue(loader.canSave)
        XCTAssertEqual(loader.originalData, bytes)
        XCTAssertLessThanOrEqual(try XCTUnwrap(loader.image).size.width, 2048)
    }

    func testFullImageRejectsDamagedOriginalInsteadOfAllowingPreviewSave() async {
        let loader = FullImageLoader(reader: { _ in Data([0, 1, 2, 3]) })
        await loader.load(from: URL(fileURLWithPath: "/synthetic/broken.png"))
        XCTAssertTrue(loader.failed)
        XCTAssertFalse(loader.canSave)
        XCTAssertNil(loader.originalData)
        XCTAssertNil(loader.image)
    }

    func testFullImageCannotSaveWhileLoadingOrAfterCancellation() async throws {
        var reply: CheckedContinuation<Data, Error>?
        let loader = FullImageLoader(reader: { _ in
            try await withCheckedThrowingContinuation { reply = $0 }
        })
        let task = Task { await loader.load(from: URL(fileURLWithPath: "/synthetic/image.png")) }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(loader.loading)
        XCTAssertFalse(loader.canSave)
        task.cancel()
        reply?.resume(returning: Data([1, 2, 3]))
        await task.value
        XCTAssertFalse(loader.loading)
        XCTAssertFalse(loader.canSave)
        XCTAssertFalse(loader.failed, "关闭全屏取消加载不应报图片失败")
        XCTAssertNil(loader.originalData)
    }

    func testOriginalDataURLPreservesEncodedImageBytes() async throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 8))
        }
        let bytes = try XCTUnwrap(original.pngData())
        let url = try XCTUnwrap(URL(string: "data:image/png;base64," + bytes.base64EncodedString()))
        let loaded = try await MediaRepository.imageData(from: url)
        XCTAssertEqual(loaded, bytes, "存相册必须读取原始编码字节，不能另存900或2048像素预览")
        XCTAssertGreaterThan(try XCTUnwrap(UIImage(data: loaded)).size.width, 2048)
    }

    func testOriginalLocalFilePreservesEncodedImageBytes() async throws {
        let original = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 8)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 8))
        }
        let bytes = try XCTUnwrap(original.pngData())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = try await MediaRepository.imageData(from: file)
        XCTAssertEqual(loaded, bytes)
    }

    func testDecoderRejectsInvalidImageData() async {
        do {
            _ = try await ImageDecoder.image(from: "data:image/png;base64,aW52YWxpZA==", remoteURL: nil)
            XCTFail("无效图片数据不应被当成图片")
        } catch {}
    }
    func testRepeatedImageDecodeReusesBoundedDecodedCache() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { c in
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = try XCTUnwrap(image.pngData())
        let source = "data:image/png;base64," + data.base64EncodedString()
        let first = try await ImageDecoder.image(from: source, remoteURL: nil)
        let second = try await ImageDecoder.image(from: source, remoteURL: nil)
        XCTAssertTrue(first === second)
    }
    func testDataURLImageDecodesAndDownsamples() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 10)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 4096, height: 10))
        }
        let png = try XCTUnwrap(image.pngData())
        let decoded = try await ImageDecoder.image(from: "data:image/png;base64," + png.base64EncodedString(), remoteURL: nil)
        XCTAssertGreaterThan(decoded.size.width, 0)
        XCTAssertLessThanOrEqual(decoded.size.width, 900,
            "聊天列表只显示 300pt 图片，不应为每张缩略图解码 2048px")
    }
    func testCancelledDecoderStopsBeforeReadingAnotherImage() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await ImageDecoder.image(from: "/missing-cancelled-image", remoteURL: nil)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled, "切出会话的已取消任务不能继续排队解图")
    }
    func testToolResultImagesAreVisibleOutsideFoldedTool() {
        let items = Protocol_.items(fromTurn: ["id": "t", "items": [["id": "tool",
            "type": "mcpToolCall", "tool": "render", "result": ["content": [
                ["type": "image", "mimeType": "image/png", "data": "aGVsbG8="]]]]]])
        XCTAssertTrue(items.contains(.image(id: "tool-image-0", url: "data:image/png;base64,aGVsbG8=")))
    }

    func testDynamicToolImageOutputIsVisible() {
        let items = Protocol_.items(fromTurn: ["id": "t", "items": [["id": "tool",
            "type": "dynamicToolCall", "tool": "render", "contentItems": [
                ["type": "inputImage", "imageUrl": "https://example.com/result.png"]]]]])
        XCTAssertTrue(items.contains(.image(id: "tool-image-0", url: "https://example.com/result.png")))
    }
    func testGeneratedImageUsesSavedPath() {
        let item = Protocol_.item(from: ["id": "generated", "type": "imageGeneration",
            "status": "completed", "savedPath": "/tmp/result.png", "result": "aGVsbG8="])
        XCTAssertEqual(item, .image(id: "generated", url: "/tmp/result.png"))
    }

    func testViewedImageIsVisible() {
        XCTAssertEqual(Protocol_.item(from: ["id": "view", "type": "imageView",
            "path": "/tmp/view.png"]), .image(id: "view", url: "/tmp/view.png"))
    }

    func testImageOnlyHistoryMessageSurvives() {
        let url = "data:image/png;base64,aGVsbG8="
        XCTAssertEqual(Protocol_.item(from: ["id": "u", "type": "userMessage",
            "content": [["type": "image", "url": url]]]),
            .user(id: "u", text: "", images: [url]))
    }

    /// 图片必须编成 `localImage` + `path`。
    func testImageUsesLocalImageWithPath() {
        let input = ConversationModel.imageInput(["/tmp/codex-pocket/a.jpg"])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "localImage",
                       "type 不是 localImage，服务端会回 ImageReference 错误")
        XCTAssertEqual(input[0]["path"] as? String, "/tmp/codex-pocket/a.jpg")
        XCTAssertNil(input[0]["url"], "localImage 不该带 url")
    }

    /// 空路径（还没传到电脑上）必须丢掉，不能发过去。
    func testEmptyPathIsDropped() {
        XCTAssertTrue(ConversationModel.imageInput([""]).isEmpty)
        XCTAssertEqual(ConversationModel.imageInput(["", "/tmp/a.png", ""]).count, 1)
    }

    /// 纯文字（没有图）时不产生任何图片条目。
    func testNoImagesNoInput() {
        XCTAssertTrue(ConversationModel.imageInput([]).isEmpty)
    }
}

import SwiftUI
import UIKit
import ImageIO
import CryptoKit
import Photos

/// 会话里的图片。点开全屏，可存相册。
///
/// 图片由桥接的 `/file?path=` 代理回来（只放行图片扩展名），
/// 本地路径的图直接读文件。
struct ImageThumb: View {
    let url: String
    @EnvironmentObject private var store: AppCoordinator
    @State private var image: UIImage?
    @State private var showFull = false
    @State private var failed = false
    @State private var retry = 0
    @State private var loadedURL: String?
    private struct LoadID: Hashable { let url: String; let retry: Int }
    private var source: String {
        if url.hasPrefix("file:"), let file = URL(string: url) { return file.path }
        return url.hasPrefix("/") ? (url.removingPercentEncoding ?? url) : url
    }

    /// 电脑上的绝对路径（agent 截图、手机刚传上去的图）。
    ///
    /// 手机读不到 `/Users/...`，要走桥接的 `/file?path=` 代理。
    /// 区分办法：手机自己的临时目录只有 `/var/mobile` 这一支。
    private var isMacPath: Bool {
        guard source.hasPrefix("/") else { return false }
        return !source.hasPrefix("/var/mobile") && !source.hasPrefix("/private/var/mobile")
    }

    private var isRemote: Bool { url.hasPrefix("http") || isMacPath }

    /// 走桥接取图。域名/端口/令牌跟主连接用同一份设置。
    private var fetchURL: URL? {
        if url.hasPrefix("http") { return URL(string: url) }
        return store.settings.bridge(path: "/file",
                                     query: [URLQueryItem(name: "path", value: source)])
    }

    var body: some View {
        Group {
            if let image {
                Button { showFull = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("查看图片")
                .accessibilityIdentifier("image.open")
            } else if failed {
                Button { retry += 1 } label: {
                    VStack(spacing: 8) {
                        LucideIcon("arrow.clockwise")
                        Text("图片没加载出来，点此重试")
                            .font(Palette.F.caption)
                    }
                    .foregroundStyle(Palette.textSub)
                    .frame(width: 160, height: 120)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("image.retry")
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.surface)
                    .frame(width: 160, height: 120)
                    .overlay(ProgressView().tint(Palette.textFaint))
            }
        }
        .task(id: LoadID(url: url, retry: retry)) { await load() }
        .fullScreenCover(isPresented: $showFull) {
            if let image {
                FullImage(image: image, source: source, remoteURL: isRemote ? fetchURL : nil)
                    .id(url)
            }
        }
    }

    private func load() async {
        guard loadedURL != url || image == nil else { return }
        guard !Task.isCancelled else { return }
        loadedURL = url
        image = nil
        failed = false
        let loaded = try? await ImageDecoder.image(from: source,
            remoteURL: isRemote ? fetchURL : nil)
        guard !Task.isCancelled else { return }
        image = loaded
        failed = loaded == nil
    }
}

@MainActor
final class PhotoSaver: ObservableObject {
    @Published var saving = false
    @Published var saved = false
    @Published var failed = false

    typealias Writer = (Data, @escaping (Error?) -> Void) -> Void
    private let writer: Writer

    init(writer: Writer? = nil) {
        self.writer = writer ?? { data, done in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                done(success ? nil : (error ?? RepositoryError(message: "图片没存成功")))
            }
        }
    }

    func save(_ data: Data) {
        guard !saving, !saved else { return }
        saving = true
        failed = false
        writer(data) { [weak self] error in
            Task { @MainActor in
                self?.saving = false
                self?.saved = error == nil
                self?.failed = error != nil
            }
        }
    }

}

@MainActor
final class FullImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var originalData: Data?
    @Published private(set) var loading = true
    @Published private(set) var failed = false
    var canSave: Bool { originalData != nil && !loading }
    private let reader: (URL) async throws -> Data
    private var sequence = 0

    init(reader: @escaping (URL) async throws -> Data = MediaRepository.imageData) {
        self.reader = reader
    }

    func load(from url: URL?) async {
        sequence += 1
        let current = sequence
        loading = true
        failed = false
        originalData = nil
        image = nil
        defer { if sequence == current { loading = false } }
        do {
            try Task.checkCancellation()
            guard let url else { throw RepositoryError(message: "图片地址无法读取") }
            let data = try await reader(url)
            try Task.checkCancellation()
            guard sequence == current else { return }
            let decoded = try await ImageDecoder.image(data: data, maxPixel: 2048)
            try Task.checkCancellation()
            guard sequence == current else { return }
            originalData = data
            image = decoded
        } catch is CancellationError { }
        catch { if !Task.isCancelled, sequence == current { failed = true } }
    }
}

/// 全屏看图：点空白关闭，右下角存原图到相册。
struct FullImage: View {
    let image: UIImage
    let source: String
    let remoteURL: URL?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var saver = PhotoSaver()
    @StateObject private var loader = FullImageLoader()
    @State private var retry = 0
    private struct LoadID: Hashable { let source: String; let remoteURL: URL?; let retry: Int }
    private var originalURL: URL? {
        remoteURL ?? (source.hasPrefix("data:") ? URL(string: source) : URL(fileURLWithPath: source))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { dismiss() }
            Image(uiImage: loader.image ?? image)
                .resizable().scaledToFit()
                .padding(.vertical, 40)
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        LucideIcon("xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.white.opacity(0.15)))
                    }
                    .accessibilityElement(children: .ignore)
        .accessibilityHidden(false)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("关闭图片")
                    .accessibilityIdentifier("viewer.close")
                }
                Spacer()
                if loader.loading {
                    HStack(spacing: 8) {
                        Spacer()
                        ProgressView().tint(.white)
                        Text("正在加载原图…").font(Palette.F.note).foregroundStyle(.white)
                    }
                    .accessibilityIdentifier("viewer.loading")
                } else if loader.failed {
                    HStack {
                        Spacer()
                        Button { retry += 1 } label: {
                            LucideLabel("原图加载失败，点此重试", "arrow.clockwise")
                                .font(Palette.F.note).foregroundStyle(.white)
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("viewer.retry")
                    }
                }
                HStack {
                    Spacer()
                    Button {
                        if let data = loader.originalData { saver.save(data) }
                    } label: {
                        LucideLabel(saver.saving ? "正在保存…" : (saver.saved ? "已存原图" : "存原图"),
                              saver.saved ? "checkmark" : "square.and.arrow.down")
                            .font(Palette.F.note)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                    .disabled(!loader.canSave || saver.saving || saver.saved)
                    .opacity(loader.canSave ? 1 : 0.5)
                    .accessibilityIdentifier("viewer.save")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .task(id: LoadID(source: source, remoteURL: remoteURL, retry: retry)) {
            await loader.load(from: originalURL)
        }
        .alert("图片没存成功", isPresented: $saver.failed) {
            Button("好", role: .cancel) { }
        } message: {
            Text("请检查相册权限和可用空间，然后重试。")
        }
    }
}

enum ImageDecoder {
    private static let cache: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>()
        value.totalCostLimit = 40 * 1024 * 1024
        value.countLimit = 40
        return value
    }()
    private static let decoding = DispatchQueue(label: "CodexPocket.ImageDecode", qos: .userInitiated)

    static func image(data: Data, maxPixel: Int) async throws -> UIImage {
        try Task.checkCancellation()
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            decoding.async {
                do { continuation.resume(returning: try decode(data, maxPixel: maxPixel)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return image
    }

    private static func decode(_ data: Data, maxPixel: Int) throws -> UIImage {
        guard let input = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(input, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
              ] as CFDictionary) else { throw RepositoryError(message: "图片格式无法读取") }
        return UIImage(cgImage: image)
    }

    static func image(from source: String, remoteURL: URL?, maxPixel: Int = 900) async throws -> UIImage {
        try Task.checkCancellation()
        // 不把 data URL（可能几 MB）放进 NSCache 的 key；那会让每张历史图片
        // 即使解码后的缩略图已淘汰，base64 字符串仍被 key 长期保留。
        let identity = remoteURL?.absoluteString ?? source
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let key = "image-\(digest)-\(maxPixel)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let remote: Data?
        if let remoteURL { remote = try await MediaRepository.imageData(from: remoteURL) }
        else { remote = nil }
        try Task.checkCancellation()
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            decoding.async {
                do {
                    let data: Data
                    if let remote { data = remote }
                    else if source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","),
                            let decoded = Data(base64Encoded: String(source[source.index(after: comma)...])) {
                        data = decoded
                    } else { data = try Data(contentsOf: URL(fileURLWithPath: source)) }
                    continuation.resume(returning: try decode(data, maxPixel: maxPixel))
                } catch { continuation.resume(throwing: error) }
            }
        }
        let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0) + key.length * 2
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}

import SwiftUI
import UIKit

/// 相册 / 拍照。选完把图存到临时目录，返回路径。
///
/// 用 UIKit 的 picker 而不是 PhotosPicker：拍照也要走同一个入口，
/// 而 PhotosPicker 只管相册。
enum PhotoPicker {
    static func present(_ source: UIImagePickerController.SourceType,
                        done: @escaping (String?) -> Void) {
        guard UIImagePickerController.isSourceTypeAvailable(source) else {
            done(nil); return
        }
        let p = UIImagePickerController()
        p.sourceType = source
        p.allowsEditing = false
        Holder.shared.done = done
        p.delegate = Holder.shared
        topController()?.present(p, animated: true)
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    final class Holder: NSObject, UIImagePickerControllerDelegate,
                        UINavigationControllerDelegate {
        static let shared = Holder()
        var done: ((String?) -> Void)?

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            let completion = done
            done = nil
            guard let img = info[.originalImage] as? UIImage else { completion?(nil); return }
            // 压到 1600px、JPEG 0.8：会话里够看，也不至于把上行撑爆。
            Task {
                let path = await Task.detached(priority: .userInitiated) { () -> String? in
                    let scaled = img.scaled(maxSide: 1600)
                    guard let data = scaled.jpegData(compressionQuality: 0.8) else { return nil }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString).jpg")
                    do { try data.write(to: url); return url.path } catch { return nil }
                }.value
                await MainActor.run { completion?(path) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            done?(nil)
            done = nil
        }
    }
}

extension UIImage {
    func scaled(maxSide: CGFloat) -> UIImage {
        let m = max(size.width, size.height)
        guard m > maxSide else { return self }
        let s = maxSide / m
        let size = CGSize(width: size.width * s, height: size.height * s)
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

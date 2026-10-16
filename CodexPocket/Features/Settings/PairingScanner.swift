import AVFoundation
import SwiftUI

struct PairingScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onResult: (String) -> Void
    let onFailure: (String) -> Void

    var body: some View {
        NavigationStack {
            CameraReader(onResult: onResult, onFailure: onFailure)
                .overlay(alignment: .bottom) {
                    Text("将电脑上的配对二维码放入画面中")
                        .font(Palette.F.body).padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .padding(24)
                }
                .navigationTitle("扫描二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.frame(minHeight: 44)
                    }
                }
        }
    }
}

private struct CameraReader: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onFailure: (String) -> Void
    func makeUIViewController(context: Context) -> QRReaderController {
        QRReaderController(onResult: onResult, onFailure: onFailure)
    }
    func updateUIViewController(_ controller: QRReaderController, context: Context) {}
}

private final class QRReaderController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let capture = AVCaptureSession()
    private let queue = DispatchQueue(label: "CodexPocket.PairingCamera")
    private let onResult: (String) -> Void
    private let onFailure: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var visible = false

    init(onResult: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        self.onResult = onResult
        self.onFailure = onFailure
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: capture)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.visible else { return }
                if allowed { self.start() }
                else { self.onFailure("未允许使用相机。可以粘贴配对链接，或在系统设置中允许相机访问。") }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        queue.async { [capture] in capture.stopRunning() }
    }

    private func start() {
        queue.async { [self] in
            if !capture.inputs.isEmpty { capture.startRunning(); return }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  capture.canAddInput(input) else {
                DispatchQueue.main.async { self.onFailure("这台设备无法打开相机，请粘贴配对链接。") }
                return
            }
            capture.beginConfiguration()
            capture.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard capture.canAddOutput(output) else {
                capture.removeInput(input)
                capture.commitConfiguration()
                DispatchQueue.main.async { self.onFailure("这台设备不支持扫码，请粘贴配对链接。") }
                return
            }
            capture.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            capture.commitConfiguration()
            capture.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard visible, !delivered,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let text = object.stringValue else { return }
        delivered = true
        queue.async { [capture] in capture.stopRunning() }
        onResult(text)
    }
}

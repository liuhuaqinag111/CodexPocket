import SwiftUI

/// 连接信息先预览，确认后才写入偏好与钥匙串。
struct PairingView: View {
    @EnvironmentObject private var store: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    let isInitial: Bool
    @State private var link = ""
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        LucideIcon("monitor", size: 32).foregroundStyle(Palette.accentText)
                            .frame(width: 64, height: 64)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                        Text("连接你的电脑").font(Palette.F.hero)
                        Text("在电脑上运行连接端，扫描它显示的二维码。没有 VPS 也能通过 Tailscale 连接。")
                            .font(Palette.F.body).foregroundStyle(Palette.textSub)
                    }
                    if let candidate = store.pairingCandidate { confirmation(candidate) }
                    else { importControls }
                    if let error = store.pairingError {
                        Text(error).font(Palette.F.note).foregroundStyle(Palette.danger)
                            .accessibilityIdentifier("pairing.error")
                    }
                }
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.bg)
            .foregroundStyle(Palette.text)
            .navigationTitle("连接电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isInitial {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }.frame(minHeight: 44)
                    }
                }
            }
            .sheet(isPresented: $scanning) {
                PairingScanner { result in
                    scanning = false
                    store.previewPairing(result)
                } onFailure: { message in
                    scanning = false
                    store.pairingError = message
                }
            }
        }
        .tint(Palette.accentText)
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { scanning = true } label: {
                LucideLabel("扫描电脑二维码", "camera").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.white)
            .accessibilityIdentifier("pairing.scan")
            TextField("粘贴 codexpocket://pair… 链接", text: $link, axis: .vertical)
                .lineLimit(2...4).font(Palette.F.note.monospaced())
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("pairing.link")
            HStack(spacing: 16) {
                PasteButton(payloadType: String.self) { strings in
                    if let input = strings.first { link = input; store.previewPairing(input) }
                }
                .labelStyle(.titleOnly)
                .accessibilityLabel("粘贴配对链接")
                Button("预览连接") { store.previewPairing(link) }
                    .frame(minHeight: 44).disabled(link.isEmpty)
                    .accessibilityIdentifier("pairing.preview")
            }
            Text("配对链接包含访问令牌，请仅使用你自己电脑生成的链接。")
                .font(Palette.F.caption).foregroundStyle(Palette.textFaint)
        }
    }

    private func confirmation(_ candidate: PairingPayload) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认连接对象").font(Palette.F.section)
            Text(candidate.name).font(Palette.F.bodyBold).accessibilityIdentifier("pairing.computer")
            Text(candidate.endpoint.absoluteString).font(Palette.F.note.monospaced())
                .textSelection(.enabled).accessibilityIdentifier("pairing.endpoint")
            if let pin = candidate.certificateSHA256 {
                VStack(alignment: .leading, spacing: 8) {
                    LucideLabel("使用电脑提供的自签证书", "shield-check").font(Palette.F.note)
                    Text(pin).font(Palette.F.mono).textSelection(.enabled)
                    Text("请核对电脑上显示的 SHA256 指纹。只信任这个地址的这张证书。")
                        .font(Palette.F.caption).foregroundStyle(Palette.textSub)
                }
            } else if candidate.endpoint.scheme == "ws" {
                Text("此地址使用未加密的 WebSocket，仅在可信局域网或已建立的 Tailscale 网络中连接。")
                    .font(Palette.F.note).foregroundStyle(Palette.warning)
            }
            Button {
                if store.confirmPairing(), !isInitial { dismiss() }
            } label: {
                Text("信任并连接").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(.white)
            .accessibilityIdentifier("pairing.confirm")
            Button("换一个连接") {
                store.pairingCandidate = nil
                store.pairingError = nil
            }
            .frame(minHeight: 44).accessibilityIdentifier("pairing.change")
        }
        .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

# iPhone 构建与安装

客户端需要 iOS 16.4 或更新版本。Windows 和 macOS 电脑都能运行连接端；构建 iPhone 客户端需要安装 Xcode 的 Mac。

## 用 Xcode 安装到自己的 iPhone

1. 打开 `CodexPocket.xcodeproj`，选择 `CodexPocket` scheme。
2. 在项目的 `Signing & Capabilities` 中选择自己的 Apple Development Team，为 App 和测试目标设置自己的唯一 Bundle Identifier。仓库默认关闭签名，真机安装前需要开启自动签名并选择签名身份。
3. 连接 iPhone、信任电脑，在需要时启用手机的开发者模式，选择该设备并运行。

Release 中的未签名 IPA 不能直接安装，需要使用自己的证书与描述文件签名。个人开发者签名的有效期和设备限制由 Apple 的账号类型决定。

## 连接自己的电脑

电脑连接端启动后，选择 Tailscale 或自己的 VPS 地址。Tailscale 的完整步骤见 [Tailscale 部署教程](tailscale.md)，VPS 见 [部署说明](vps.md)。在 App 的连接设置打开配对，扫描电脑控制面板二维码；不方便扫码时可粘贴配对链接。确认电脑名称与地址，再点击信任并连接。

使用 Tailscale 时，iPhone 也要从 App Store 安装 Tailscale，登录与电脑相同的 tailnet，允许添加 VPN 配置并保持“已连接”，然后再扫码配对。个人使用时，两端用同一个账号登录即可。

新安装不预填服务器。配对凭据存入系统 Keychain；二维码与配对链接包含凭据，不要发到公开 issue。VPS 方式见 [部署说明](vps.md)。

## 从命令行验证

先用 `xcrun simctl list devices available` 查看已安装的模拟器，再将下面的 `SIMULATOR_UDID` 换成该设备 ID。命令只运行本地单元测试，不访问自己的 Codex 服务，也不运行真实服务器界面测试。

```sh
xcodebuild test -project CodexPocket.xcodeproj -scheme CodexPocket \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/CodexPocketDerivedData \
  -only-testing:CodexPocketTests CODE_SIGNING_ALLOWED=NO
```

模拟器不具备 iPhone 相机扫码能力，可粘贴配对链接测试。实际扫码、后台行为和相册保存应在真机上确认。

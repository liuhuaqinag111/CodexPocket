# CodexPocket

An open-source native iPhone companion for your own Codex on Windows and macOS.

把自己电脑上的 Codex 项目、会话和任务接到 iPhone。每个人使用自己的电脑和账号，会话保存在自己的电脑上。

**QQ 交流群：974685560**

## 下载与安装

在本仓库的 **Releases** 下载对应连接端，解压整个文件夹：

| 电脑 | 安装入口 |
| --- | --- |
| Windows x64 | `Install.cmd` |
| Intel Mac | `Install.command`（macos-x64 包） |
| Apple Silicon Mac | `Install.command`（macos-arm64 包） |

安装包内置 Node.js，不需要单独安装 Node。安装以当前用户运行；`Start` 打开控制面板，`Stop` 停止连接端，`Uninstall` 删除启动项和程序、保留用户数据。

电脑上需要 Codex 桌面版或 CLI，可以使用官方账号、API Key，也可以使用 **CC Switch 已配置的第三方 API／中转**，不要求登录 Codex 官方账号。连接端复用当前用户的配置，不改写模型、服务商或全局代理。已验证 CLI `0.149.0-alpha.4.3`；连接端会检查 app-server 支持情况。

## 连接手机

1. 运行连接端，控制面板会自动打开。
2. 没有 VPS：**电脑和 iPhone 都安装 Tailscale，并登录同一个 tailnet**，按 [Tailscale 部署教程](docs/public/tailscale.md) 启用私网 HTTPS。有 VPS：[配置自己的 HTTPS 入口](docs/public/vps.md)，在面板保存 WSS 地址。
3. 在 iPhone 的 CodexPocket 中扫描二维码，核对电脑名、地址后点击“信任并连接”。也可复制配对链接，在 App 中粘贴。

Tailscale 模式只使用私有 tailnet，不启用 Funnel。已有其他服务时尝试独立端口，不覆盖其他服务。二维码包含连接凭据，请仅用于自己的手机。

iPhone 客户端是原生 SwiftUI App。[Xcode 构建与安装](docs/public/ios.md)。Release 中的未签名 IPA 需要用你自己的签名方式安装。

## 从源码运行

需要 Node.js 24：

```sh
npm ci
npm run doctor
npm start
```

自动识别失败时可指定 CLI：`node connector/cli.mjs start --codex /path/to/codex --open`。`--data-dir` 可指定独立配置目录。

## 开发与验证

```sh
npm ci
npm test
```

测试使用临时目录与合成服务，不连接个人 Codex 或 Tailscale。Windows 运行跨平台连接端、桥接单元测试与包装检查；依赖 POSIX shell 的旧桥接集成测试在 macOS/Linux 运行。iOS 单元测试命令见 [iPhone 构建与安装](docs/public/ios.md)。

更多说明：[Tailscale 部署](docs/public/tailscale.md) · [自有 VPS 部署](docs/public/vps.md) · [架构与数据边界](docs/public/architecture.md)。

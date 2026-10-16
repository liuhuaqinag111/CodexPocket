# Tailscale 部署（无 VPS）

Tailscale 适合不想购买 VPS 的情况。**电脑和 iPhone 都要安装 Tailscale，并登录同一个 tailnet**，连接端只通过 Tailscale 私网 HTTPS 暴露，不启用 Funnel，不把 Codex 或管理端口公开到互联网。

## 1. 安装并登录

先在电脑安装并登录 Tailscale：

- Windows：安装官方 Tailscale 客户端并登录。
- macOS：安装 Tailscale.app 并登录。

再设置 iPhone（手机也必须安装，不能只在电脑上安装）：

1. 在 App Store 搜索并安装 **Tailscale**。
2. 打开 Tailscale，登录与电脑相同的网络（tailnet）；个人使用时，两端用同一个账号登录即可。
3. 按系统提示允许添加 VPN 配置，开启 Tailscale，确认状态为“已连接”（Connected）。
4. 在设备列表确认电脑在线，再打开 CodexPocket 扫码配对。使用期间保持手机 Tailscale 连接开启。

电脑端可以检查：

```sh
tailscale status
tailscale ip
```

## 2. 启动连接端

解压对应平台的连接端，运行 `Start.cmd`（Windows）或 `Start.command`（macOS）。也可以从源码运行：

```sh
npm start
```

控制面板打开后，确认 Codex 已识别且状态为运行中。

## 3. 启用 Tailscale HTTPS

在控制面板选择 **Tailscale**，点击 **启用 Tailscale 连接**。连接端会：

1. 检查 Tailscale 是否在线并读取本机 MagicDNS 名称；
2. 优先使用 HTTPS 443，已被其他 Serve 配置占用时尝试 8443；
3. 只把本连接端的本机桥接端口接到 Tailscale Serve；
4. 检查 Serve 状态，确认配置确实属于 CodexPocket；
5. 生成 `wss://电脑名称.tail.../ws` 配对地址。

连接端不会覆盖其他服务。如果 443 和 8443 都有别的 Serve 配置，启用会失败并保留原配置。

命令行等价操作：

```sh
node connector/cli.mjs start
node connector/cli.mjs tailscale
node connector/cli.mjs pair
```

## 4. 配对 iPhone

1. 在电脑控制面板显示二维码。
2. 在 CodexPocket 中点“扫描电脑二维码”。
3. 核对电脑名称和 `wss://` 地址。
4. 点击“信任并连接”。

扫码不方便时，在控制面板复制配对链接，在 App 中粘贴。配对令牌保存在 iPhone Keychain，不要把二维码或链接发到公开群组、Issue 或截图中。

## 5. 验证链路

```sh
node connector/cli.mjs status
```

确认 `running` 为 `true`、`externalURL` 是 Tailscale 的 `wss://` 地址，并发送一条测试消息。Tailscale ACL 需要允许 iPhone 访问电脑的 HTTPS Serve 端口。不要开放 Funnel，也不要做路由器端口转发或公开 `bridgePort`/`upstreamPort`。

## 常见问题

### 显示“请先安装 Tailscale”

确认电脑端 Tailscale 已登录且状态为 Running，再重新启动连接端。Windows 检查 Tailscale 客户端服务；macOS 检查菜单栏状态。

### 手机打不开配对地址

两台设备必须登录同一个 tailnet，且 MagicDNS 可用。先确认手机端 Tailscale 能看到电脑在线，再重新点击启用 Tailscale。

### 443 和 8443 都被占用

连接端不会覆盖已有配置。清理确认属于自己的旧 Serve 规则，或停止占用对应端口的自有服务后重试。

### 切换网络后断线

等待 Tailscale 恢复在线，回到 App 重连。不要同时启动第二个连接端实例。

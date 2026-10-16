# 使用自己的 VPS

没有 VPS 时直接使用控制面板里的 Tailscale。以下方案适合已有 VPS、域名与 SSH 登录权限的用户：电脑主动建立反向 SSH 隧道，VPS 用 Nginx 提供 HTTPS。Windows 与 macOS 使用相同连接方式。

请求路径为 `iPhone → 自己的 HTTPS 域名 → VPS 上的 127.0.0.1:16313 → SSH 隧道 → 电脑 127.0.0.1:63713`。连接端的上游 app-server 与本机管理面板不通过隧道公开。

## 建立隧道

先启动连接端并确认运行正常。电脑需要 OpenSSH 客户端，VPS 的 SSH 服务需要允许 TCP forwarding。用自己 VPS 上的普通用户替换 `VPS_USER`，用自己的主机名替换 `VPS_HOST`：

```sh
ssh -NT -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -R 127.0.0.1:16313:127.0.0.1:63713 VPS_USER@VPS_HOST
```

PowerShell 请将该命令写在一行。首次连接时核对 VPS 的 SSH 主机指纹。`63713` 必须与连接端设置一致；隧道进程需保持运行，断网后重新运行。VPS 的 `16313` 只监听 loopback，不需要开放该端口的防火墙。

## 配置 HTTPS

把自己的域名解析到 VPS。以下示例使用 Ubuntu/Debian 与域名占位符 `codex.example.com`；先替换为自己的域名。

```sh
sudo apt update
sudo apt install nginx certbot python3-certbot-nginx
```

将以下配置保存为 `/etc/nginx/conf.d/codexpocket.conf`：

```nginx
map $http_upgrade $codexpocket_connection {
    default upgrade;
    '' close;
}
server {
    listen 80;
    server_name codex.example.com;
    client_max_body_size 24m;
    location / {
        proxy_pass http://127.0.0.1:16313;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $codexpocket_connection;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
```

检查并加载配置，再申请证书与 HTTPS 重定向：

```sh
sudo nginx -t
sudo systemctl reload nginx
sudo certbot --nginx -d codex.example.com --redirect
```

VPS 防火墙需允许 HTTPS `443`，证书首次申请及 HTTP 验证续期需要 `80`，SSH 端口按自己的设置保留。不要公开连接端上游和管理端口。证书到期前确保 Certbot 自动续期任务正常运行。

## 完成配对

1. 在 VPS 执行 `curl http://127.0.0.1:16313/status`，确认返回 `upstreamReady: true`。
2. 从外部访问 `https://codex.example.com/status`，确认域名、证书和隧道均正常。
3. 在电脑控制面板保存 `wss://codex.example.com/ws`，再扫描二维码连接手机。

HTTPS 使用系统信任的证书即可，不需要填证书指纹。配对令牌由电脑端自动生成，不要把令牌放进 Nginx 配置或地址查询参数。

遇到 `502` 先确认电脑连接端与 SSH 隧道都在运行；连上后图片上传失败，检查 Nginx 的请求体大小和 `/upload` 是否也转发到同一个连接端；WebSocket 反复掉线，检查 Upgrade 头、超时以及 VPS 前置代理的长连接设置。

连接端不会管理第三方 SSH 服务，也不会自动修改 VPS。长期运行可用自己的用户服务管理上述 SSH 命令；保留 `ExitOnForwardFailure` 和 keepalive 参数，避免隧道失败后误以为仍已连接。

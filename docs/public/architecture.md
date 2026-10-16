# Architecture

CodexPocket keeps each user's Codex account, projects and conversation data on their own computer. The iPhone connects to that computer's connector; it never uses a shared author account or backend.

The same Node.js connector runs on Windows and macOS. It discovers the user's native Codex CLI, starts an owned loopback app-server and bridge, and provides a loopback control panel. It preserves the existing writer isolation, submission ledger and approval routing.

Network choices are Tailscale Serve (private HTTPS inside the user's tailnet) or the user's own VPS with a TLS reverse tunnel. The connector never overwrites unrelated Tailscale services or stops another Codex process.

Pairing uses `codexpocket://pair?data=<base64url-json>` containing version 1, endpoint, computer name, per-computer random token and an optional explicit certificate SHA256. The iPhone shows a confirmation before saving credentials in Keychain. Normal HTTPS uses system trust.

Control APIs bind to loopback, require an independent admin token, and validate Host and Origin. Pairing secrets are available only to that local administrator. Logs, personal configuration, caches and the development repository's history are excluded from the public source export.

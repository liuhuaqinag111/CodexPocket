#!/bin/bash
# 前台常驻：确保 app-server 在跑（带看门狗），前台运行桥接（交给 launchd KeepAlive 守护）
#
# 原来只在启动时检查一次 app-server。它一旦退出，桥接就一直
# ECONNREFUSED 重试，手机端表现是"连不上"，而且永远不会自己恢复 ——
# 实测 2026-09-22 就这么断过一次。所以加一层看门狗。
set -uo pipefail
export SUPERVISOR_PID=$$
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
TOKEN_FILE="${TOKEN_FILE:-$HOME/.codex/phone-token}"
# 62115 而不是 62112：62112 是桌面端 app-server 的老实例，
# 长跑之后会卡在 "Server is draining"（实测：thread/start 100% 失败，
# thread/list 却正常）。手机走一个独立实例，桌面端重启也不影响手机。
WS_PORT="${WS_PORT:-62115}"
UI_PORT="${UI_PORT:-62113}"
# 手机端空闲这么久就把 app-server 重启一次：会话一旦被加载就会一直占着
# ~/.codex/thread-writer-locks/<id>.lock（协议里没有卸载会话的方法），
# 桌面端就再也打不开那些会话。桥接负责计时，这里只管给值。
IDLE_RESTART_MS="${IDLE_RESTART_MS:-600000}"
NODE="${NODE_BIN:-$(command -v node)}"
export UPSTREAM_PID_FILE="${UPSTREAM_PID_FILE:-$DIR/app-server.pid}"
# codex 二进制的路径**会随 ChatGPT.app 更新变**：
# 2026-09-26 app 升级后，Resources/codex 消失，换成了
# Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex。
# 硬编码那一次的结果就是手机整晚连不上（桥接没上游，ECONNREFUSED）。
# 所以每次拉起 app-server 都重新找一遍。
find_codex() {
  local c
  if [ -n "${CODEX_BIN:-}" ] && [ -x "${CODEX_BIN}" ]; then
    printf '%s' "${CODEX_BIN}"; return 0
  fi
  c="$(command -v codex 2>/dev/null)"
  if [ -n "$c" ] && [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
  for c in \
    /Applications/ChatGPT.app/Contents/Resources/codex \
    /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex \
    "$HOME/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
    /Applications/Codex.app/Contents/Resources/codex; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  # 兜底：直接扫 ChatGPT.app，将来再换目录也能找到。
  for c in /Applications/ChatGPT.app/Contents/Resources/codex-cli/*.app/Contents/MacOS/codex \
           /Applications/ChatGPT.app/Contents/Resources/*/codex; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

if [ ! -s "$TOKEN_FILE" ]; then
  mkdir -p "$(dirname "$TOKEN_FILE")"; openssl rand -hex 32 > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
fi

start_ws() {
  lsof -nP -iTCP:"$WS_PORT" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  local CODEX
  CODEX="$(find_codex)" || {
    echo "$(date -u +%FT%TZ) 找不到 codex 二进制，等下一轮再试"
    return 1
  }
  echo "$(date -u +%FT%TZ) app-server 不在 :$WS_PORT，拉起（$CODEX）"
  ulimit -n 65536 2>/dev/null || true
  "$CODEX" app-server --listen "ws://0.0.0.0:$WS_PORT" \
    --ws-auth capability-token --ws-token-file "$TOKEN_FILE" \
    </dev/null >> "$DIR/app-server.log" 2>&1 &
  echo $! > "$UPSTREAM_PID_FILE"
}

maintain_upstream() {
  curl -fsS --max-time 30 -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    "http://127.0.0.1:$UI_PORT/maintenance" 2>/dev/null | grep -q '"released":true'
}

# 端口归其它进程所有时退出，绝不驱逐浏览器或其它 bridge。
free_ui_port() {
  local pids p cmd
  pids="$(lsof -t -iTCP:"$UI_PORT" -sTCP:LISTEN 2>/dev/null | sort -u)"
  [ -z "$pids" ] && return 0
  for p in $pids; do
    cmd="$(ps -o command= -p "$p" 2>/dev/null)"
    [ -z "$cmd" ] && continue
    echo "$(date -u +%FT%TZ) 端口 $UI_PORT 被占: pid=$p $(echo "$cmd" | cut -c1-90)"
    case "$cmd" in
      *) return 1 ;;
    esac
  done
  sleep 1
}
free_ui_port || exit 1
start_ws
sleep 3

# IPA_PATH 显式指到 ~/.codex/phone/ 下的一份。
#
# 以前桥接默认读 ~/Desktop/CodexPocket.ipa —— 而桌面开着 iCloud 同步，
# 往那儿 `cp` 一个 3MB 的包会卡死（实测卡了 22 分钟没返回，
# ship.sh 整个跑不完，Bark 也发不出去）。桌面是同步盘，不是可靠的投递目录。
#
# 注释必须写在**赋值链之前**：`\` + 换行会把两行接成一行，
# 注释插在链条中间会把后面所有赋值连同启动命令一起注释掉 ——
# 桥接于是退回它自己的默认上游 62112（早就没有的端口），
# 表现是"连上了但一个会话都加载不出来"（2026-10-06 实测踩过）。
UPSTREAM="ws://127.0.0.1:$WS_PORT" PORT="$UI_PORT" BIND="${BIND:-0.0.0.0}" \
  IDLE_RESTART_MS="$IDLE_RESTART_MS" \
  IPA_PATH="${IPA_PATH:-$DIR/CodexPocket.ipa}" \
  "$NODE" "$DIR/bridge.mjs" "$TOKEN_FILE" >> "$DIR/agent.log" 2>&1 &
BRIDGE=$!

# 看门狗两件事：1) app-server 不在就拉起；2) 在但卡在 draining 就重启它。
#
# 为什么需要第 2 件：实测 2026-09-26，app-server 跑了 2 天 20 小时后
# thread/start 100% 返回 "Server is draining"，而 thread/list 完全正常
# —— readyz 也是 200。表现就是手机"已连接"但新会话建不了、点进去卡住。
# 只探端口存活完全测不出来。
fail=0
while kill -0 "$BRIDGE" 2>/dev/null; do
  sleep 30
  start_ws
  # FD 泄漏看门狗：app-server 会重复打开同一个 rollout 文件不放，
  # 上限一到就整个进程废掉。与其等它撞墙，不如提前回收。
  wspid="$(pgrep -f "app-server --listen ws://0.0.0.0:$WS_PORT" | head -1)"
  if [ -n "$wspid" ]; then
    nfd="$(lsof -p "$wspid" 2>/dev/null | wc -l | tr -d ' ')"
    if [ -n "$nfd" ] && [ "$nfd" -gt 4000 ]; then
      echo "$(date -u +%FT%TZ) app-server FD 数 $nfd 过高，申请空闲维护"
      if maintain_upstream; then
        sleep 3; start_ws; fail=0; continue
      fi
    fi
  fi
  # 模型目录变了（CC Switch 切供应商会重写它）就重启 app-server。
  #
  # 为什么必须重启：`model/list` 是 app-server **启动时**读一次
  # `~/.codex/cc-switch-model-catalog.json` 缓存在内存里的。
  # 文件变了它不会重读 —— 手机端于是永远显示旧模型，
  # 和桌面端 config.toml 里的模型对不上（用户报的
  # "为什么电脑端和手机显示的模型不一样"）。
  # 实测：目录是 global:deepseek-v4.1-flash，手机却报 cn:deepseek-v4.1-flash，
  # 杀掉 app-server 重拉之后立刻变回 global:。
  CATALOG="$HOME/.codex/cc-switch-model-catalog.json"
  CAT_SIG=""
  if [ -f "$CATALOG" ]; then
    CAT_SIG="$(stat -f '%m' "$CATALOG" 2>/dev/null || stat -c '%Y' "$CATALOG" 2>/dev/null)"
  fi
  if [ -n "$CAT_SIG" ] && [ "$CAT_SIG" != "${LAST_CAT_SIG:-}" ] && [ -n "${LAST_CAT_SIG:-}" ]; then
    if maintain_upstream; then
      sleep 3; start_ws; LAST_CAT_SIG="$CAT_SIG"; fail=0
    fi
    continue
  fi
  LAST_CAT_SIG="$CAT_SIG"

  # 桥接的上游端口对不对。
  #
  # 2026-10-06 踩过：supervise.sh 里一段注释插进了 `\` 续行链中间，
  # 把后面的赋值连同启动命令一起注释掉了，桥接于是用它自己的默认上游
  # 62112（早就没有的端口）。app-server 明明在 62115 跑得好好的，
  # 手机也显示"已连接"，但一个会话都加载不出来。
  # `/healthz` 那种探针看不出来（它永远回 ok），所以单独查端口。
  if ! curl -s --max-time 5 "http://127.0.0.1:$UI_PORT/status" 2>/dev/null \
       | grep -q "\"upstreamPort\": *\"$WS_PORT\""; then
    echo "$(date -u +%FT%TZ) 桥接状态不可验证（应为 $WS_PORT），保留进程等待下一次检查"
    continue
  fi

  if ! "$NODE" "$DIR/health.mjs" "$WS_PORT" >/dev/null 2>&1; then
    fail=$((fail + 1))
    echo "$(date -u +%FT%TZ) app-server 不健康（第 $fail 次），重启"
    if [ "$fail" -ge 2 ]; then
      if maintain_upstream; then
        sleep 3; start_ws; fail=0
      fi
    fi
  else
    fail=0
  fi
done

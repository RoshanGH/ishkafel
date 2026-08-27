#!/usr/bin/env bash
# 用**新构建的产物**重启 app。
#
#   ./scripts/restart_app.sh
#
# 为什么要有这个脚本：macOS 的 `open -a` 对**已经在跑**的 app 只是「激活
# 窗口」，不会加载新的二进制。所以打完包直接 open，用户看到的还是上一版
# ——真机上撞过好几次：说好的新功能「没有生效」，其实是根本没启动新版，
# 用户只好自己退出再打开一遍。
#
# 退出要**优雅**：直接 pkill 的话 app 来不及落盘、来不及放任务锁，
# 下次进来会看到「上一次没有正常退出」的只读横幅（锁要等 60 秒心跳超时）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/macos/Build/Products/Release/ishkafel.app}"
if [ ! -d "$APP" ]; then
  echo "找不到产物：${APP}（先跑 ./scripts/build_macos.sh --release 或 ./scripts/pack.sh）" >&2
  exit 1
fi

if pgrep -f "$APP/Contents/MacOS/ishkafel" >/dev/null 2>&1; then
  echo "退出正在运行的旧版本…"
  osascript -e 'quit app "ishkafel"' >/dev/null 2>&1 || true
  # 等它自己走完退出流程（落盘、放锁）。最多等 10 秒
  for _ in $(seq 1 20); do
    pgrep -f "$APP/Contents/MacOS/ishkafel" >/dev/null 2>&1 || break
    sleep 0.5
  done
  # 还赖着不走才强杀——这时数据多半已经落盘了
  if pgrep -f "$APP/Contents/MacOS/ishkafel" >/dev/null 2>&1; then
    echo "没有响应退出请求，强制结束" >&2
    pkill -f "$APP/Contents/MacOS/ishkafel" || true
    sleep 1
  fi
fi

open "$APP"
sleep 3
# Flutter 窗口对 `tell app activate` 不响应，要走 System Events
osascript -e 'tell application "System Events" to tell process "ishkafel" to set frontmost to true' >/dev/null 2>&1 || true

VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
echo "已启动 ${VER}（${APP}）"

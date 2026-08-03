#!/usr/bin/env bash
# 构建 macOS app，并把火山三把 key 编进产物里。
#
# 为什么要有这个脚本：app 双击启动时进程的工作目录是 `/`，项目里的 .secrets
# 永远读不到，于是打出来的包一进去就是「尚未配置 AI 服务」。用
# --dart-define 在编译期注入，产物自带 key，拿到哪台机器都能直接用。
#
# key 只从本机 .secrets/ 读，不进源码、不进 git。想换 key 就改 .secrets 里的
# 文件再跑一次这个脚本。
#
#   ./scripts/build_macos.sh            # debug
#   ./scripts/build_macos.sh --release  # release
set -euo pipefail

cd "$(dirname "$0")/.."
SECRETS=".secrets"

read_key() {
  local file="$SECRETS/$1"
  if [[ ! -f "$file" ]]; then
    echo "缺少 $file —— 火山的三把 key 都要放在 $SECRETS/ 下：" >&2
    echo "  ark_api_key           方舟大模型（语义切分、打标、视觉理解）" >&2
    echo "  speech_app_id         语音服务 AppID（ASR 转写、TTS 配音）" >&2
    echo "  speech_access_token   语音服务 Access Token" >&2
    exit 1
  fi
  tr -d '[:space:]' < "$file"
}

ARK="$(read_key ark_api_key)"
APP_ID="$(read_key speech_app_id)"
TOKEN="$(read_key speech_access_token)"

MODE="${1:---debug}"

flutter build macos "$MODE" \
  --dart-define=ARK_API_KEY="$ARK" \
  --dart-define=SPEECH_APP_ID="$APP_ID" \
  --dart-define=SPEECH_ACCESS_TOKEN="$TOKEN"

# 只报路径，绝不回显 key
case "$MODE" in
  --release) OUT="build/macos/Build/Products/Release/ishkafel.app" ;;
  *)         OUT="build/macos/Build/Products/Debug/ishkafel.app" ;;
esac
echo "已构建（凭据已编入产物）：$OUT"

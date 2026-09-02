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

# 自动更新的落点。**可选**：这几个文件不在就不注入，产物里的更新入口
# 整个不显示（不能摆一个点下去永远报错的按钮）。
#
# update_tos_ak / update_tos_sk 应当是一对**只读**凭据，只有这一个 bucket 的
# GetObject 权限——它和别的 key 一样明文躺在产物里（strings 一抠就有），
# 这正是安装包必须私有存放的原因：泄露的后果只该是「别人能下载安装包」，
# 而不是「别人能花你的钱」。
read_optional() {
  local file="$SECRETS/$1"
  [[ -f "$file" ]] && tr -d '[:space:]' < "$file" || echo ""
}
UP_REGION="$(read_optional update_tos_region)"
UP_BUCKET="$(read_optional update_tos_bucket)"
UP_ENDPOINT="$(read_optional update_tos_endpoint)"
UP_AK="$(read_optional update_tos_ak)"
UP_SK="$(read_optional update_tos_sk)"

MODE="${1:---debug}"

flutter build macos "$MODE" \
  --dart-define=ARK_API_KEY="$ARK" \
  --dart-define=SPEECH_APP_ID="$APP_ID" \
  --dart-define=SPEECH_ACCESS_TOKEN="$TOKEN" \
  --dart-define=UPDATE_TOS_REGION="$UP_REGION" \
  --dart-define=UPDATE_TOS_BUCKET="$UP_BUCKET" \
  --dart-define=UPDATE_TOS_ENDPOINT="$UP_ENDPOINT" \
  --dart-define=UPDATE_TOS_AK="$UP_AK" \
  --dart-define=UPDATE_TOS_SK="$UP_SK"

# 只报路径，绝不回显 key
case "$MODE" in
  --release) OUT="build/macos/Build/Products/Release/ishkafel.app" ;;
  *)         OUT="build/macos/Build/Products/Debug/ishkafel.app" ;;
esac
# 用固定的自签名证书签一次。
#
# **不签的话每次重新编译都会重新弹一遍隐私授权框**（「ishkafel 想访问
# 文稿文件夹」）：adhoc 签名没有稳定身份，macOS 只能按二进制哈希认它，
# 编译一次哈希就变一次，系统当成另一个 app。真机上因此还出过更糟的：
# 授权框挡住了建任务，而命令行那头报了「已经建好了」。
#
# 证书是本地自签的（`.secrets/codesign.p12`，不进 git、不联网、
# 不涉及任何账号）。没有它就退回 adhoc——授权框会照旧每次弹，
# 但不影响构建。
CERT_P12=".secrets/codesign.p12"
if [ -f "$CERT_P12" ]; then
  IDENTITY="ishkafel Local Signing"
  if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "把签名证书导入钥匙串（只做一次）…"
    security import "$CERT_P12" -k ~/Library/Keychains/login.keychain-db \
      -T /usr/bin/codesign -P "$(cat .secrets/codesign.pass)" >/dev/null
  fi
  # --deep 连同内嵌的 framework 一起签：少签一个，系统就认为整包无效
  if codesign --force --sign "$IDENTITY" --deep "$OUT" 2>/dev/null; then
    echo "已签名（${IDENTITY}）——隐私授权不会每次重新编译都再问一遍"
  else
    echo "签名失败，退回 adhoc：授权框每次重新编译还会再弹一次" >&2
  fi
else
  echo "没有 .secrets/codesign.p12，产物是 adhoc 签名——" >&2
  echo "每次重新编译都会重新弹一次隐私授权框" >&2
fi

echo "已构建（凭据已编入产物）：$OUT"

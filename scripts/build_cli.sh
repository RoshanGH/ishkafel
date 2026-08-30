#!/usr/bin/env bash
# 构建 CLI。默认两个架构都编（Apple Silicon + Intel），因为这份东西最终要塞进
# .app 发给别人——只有一个架构的二进制拷到另一种 Mac 上直接「Bad CPU type」，
# 而这件事要等对方敲下命令那一刻才暴露。
#
#   ./scripts/build_cli.sh                       # 能编两个就编两个
#   ./scripts/build_cli.sh --require-universal   # 编不齐就失败（打包用）
#
# 为什么不是 `dart compile exe`：media_kit 的传递依赖 objective_c 带 build
# hooks，`dart compile` 不支持这个组合，会直接报错让你改用 `dart build`。
#
# 为什么要另外装一个 x64 的 Dart SDK：Dart **不支持交叉编译**，`dart build cli`
# 只能产出当前机器的架构。Go 那种 `GOARCH=amd64` 在这儿没有对应物，所以只能
# 让 x64 的 Dart 在 Rosetta 下再编一遍。
#
# 为什么不 lipo 成一个 universal 二进制：`dart build cli` 产出的可执行文件是
# **dartaotruntime 后面附加了 AOT 快照**，lipo 只认 Mach-O 那一段，合完快照
# 就没了——跑起来报 "not an AOT snapshot"。所以两份并存，用一个分发脚本按
# `uname -m` 选。
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_BOTH=0
[[ "${1:-}" == "--require-universal" ]] && REQUIRE_BOTH=1

# x64 的 Dart SDK 放哪儿。可以用环境变量覆盖
DART_X64="${ISHKAFEL_DART_X64:-$HOME/sdk/dart-sdk-x64/bin/dart}"

case "$(uname -m)" in
  arm64) NATIVE="macos_arm64"; OTHER="macos_x64" ;;
  x86_64) NATIVE="macos_x64"; OTHER="macos_arm64" ;;
  *) echo "不认识的架构：$(uname -m)" >&2; exit 1 ;;
esac

echo "编本机架构（${NATIVE}）…"
dart build cli
[[ -x "build/cli/$NATIVE/bundle/bin/ishkafel" ]] || {
  echo "没找到产物：build/cli/$NATIVE/bundle/bin/ishkafel" >&2; exit 1
}

BOTH=0
if [[ "$NATIVE" == "macos_arm64" && -x "$DART_X64" ]]; then
  echo "编另一个架构（${OTHER}，走 Rosetta）…"
  arch -x86_64 "$DART_X64" build cli
  [[ -x "build/cli/$OTHER/bundle/bin/ishkafel" ]] && BOTH=1
fi

# 分发目录：两份 bundle + 一个按机器选的入口脚本。塞进 .app 的就是这个目录
DIST="build/cli/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "build/cli/$NATIVE" "$DIST/$NATIVE"
[[ "$BOTH" == 1 ]] && cp -R "build/cli/$OTHER" "$DIST/$OTHER"

# 入口脚本。用它而不是软链到某个 bundle：bundle 里的可执行文件靠相对路径找
# lib/*.dylib，软链过去会让它找不到
cat > "$DIST/ishkafel" <<'ENTRY'
#!/bin/sh
# 按机器架构选对应的那份。两份都在，谁的机器都能跑
DIR="$(cd "$(dirname "$0")" && pwd)"
case "$(uname -m)" in
  arm64)  TARGET="$DIR/macos_arm64/bundle/bin/ishkafel" ;;
  x86_64) TARGET="$DIR/macos_x64/bundle/bin/ishkafel" ;;
  *) echo "不支持的架构：$(uname -m)" >&2; exit 1 ;;
esac
if [ ! -x "$TARGET" ]; then
  echo "这个包里没有 $(uname -m) 架构的命令行工具。" >&2
  exit 1
fi
exec "$TARGET" "$@"
ENTRY
chmod 755 "$DIST/ishkafel"

if [[ "$BOTH" == 0 ]]; then
  MSG="只编出了 $NATIVE 一个架构。另一个架构需要一份 x64 的 Dart SDK：
  1. 下载（国内源慢的话用 storage.googleapis.com，它支持分块并行）：
     https://storage.flutter-io.cn/dart-archive/channels/stable/release/<dart --version 里的版本>/sdk/dartsdk-macos-x64-release.zip
  2. 解压到 ~/sdk/dart-sdk-x64（或用 ISHKAFEL_DART_X64 指到它的 bin/dart）
  3. 重跑本脚本"
  if [[ "$REQUIRE_BOTH" == 1 ]]; then
    echo "$MSG" >&2
    exit 1
  fi
  echo "$MSG" >&2
fi

# 包装脚本而不是软链：入口脚本靠 `dirname $0` 找两份 bundle，
# 软链过去 $0 指的是软链自己所在的目录，找不到东西
cat > build/ishkafel <<'SHIM'
#!/bin/sh
exec "$(cd "$(dirname "$0")" && pwd)/cli/dist/ishkafel" "$@"
SHIM
chmod 755 build/ishkafel

# 给命令行工具也签上名。
#
# **它和 app 同名（都叫 ishkafel）**，所以它读 ~/Documents 下的原片时，
# 系统弹的是一模一样的「ishkafel 想访问文稿文件夹」——人根本分不清这次
# 是谁在问。而它没签名，每次重新编译都换一个身份，于是授权永远记不住：
# app 那半签好了，这半还在天天弹。
CERT_P12=".secrets/codesign.p12"
if [ -f "$CERT_P12" ]; then
  SIGN_ID="ishkafel Local Signing"
  if ! security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    security import "$CERT_P12" -k ~/Library/Keychains/login.keychain-db \
      -T /usr/bin/codesign -P "$(cat .secrets/codesign.pass)" >/dev/null 2>&1 || true
  fi
  for BIN in "$DIST"/../*/bundle/bin/ishkafel; do
    [ -f "$BIN" ] && codesign --force --sign "$SIGN_ID" "$BIN" 2>/dev/null || true
  done
  echo "命令行工具已签名——授权框不会每次重新编译都再问一遍"
else
  echo "没有 .secrets/codesign.p12，命令行工具是未签名的——" >&2
  echo "它读文稿目录时会反复弹授权框（和 app 同名，看不出是谁在问）" >&2
fi

echo "好了：build/ishkafel  →  $DIST/ishkafel"
[[ "$BOTH" == 1 ]] && echo "两个架构都在：macos_arm64 + macos_x64"

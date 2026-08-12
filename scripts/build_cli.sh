#!/usr/bin/env bash
# 构建 CLI。默认产出 **universal**（Apple Silicon + Intel 通用），因为这份东西
# 最终要塞进 .app 发给别人——只有一个架构的二进制拷到另一种 Mac 上直接
# 「Bad CPU type」，而这件事要等对方敲下命令那一刻才暴露。
#
#   ./scripts/build_cli.sh            # 能编 universal 就编，缺 x64 SDK 就只编本机的
#   ./scripts/build_cli.sh --require-universal   # 编不出 universal 就失败（打包用）
#
# 为什么不是 `dart compile exe`：media_kit 的传递依赖 objective_c 带 build
# hooks，`dart compile` 不支持这个组合，会直接报错让你改用 `dart build`。
#
# 为什么要另外装一个 x64 的 Dart SDK：Dart **不支持交叉编译**，`dart build cli`
# 只能产出当前机器的架构。Go 那种 `GOARCH=amd64` 在这儿没有对应物，所以只能
# 让 x64 的 Dart 在 Rosetta 下再编一遍，最后 lipo 合起来。
set -euo pipefail
cd "$(dirname "$0")/.."

REQUIRE_UNIVERSAL=0
[[ "${1:-}" == "--require-universal" ]] && REQUIRE_UNIVERSAL=1

# x64 的 Dart SDK 放哪儿。可以用环境变量覆盖
DART_X64="${ISHKAFEL_DART_X64:-$HOME/sdk/dart-sdk-x64/bin/dart}"

host_target() {
  case "$(uname -m)" in
    arm64) echo "macos_arm64" ;;
    x86_64) echo "macos_x64" ;;
    *) echo "不认识的架构：$(uname -m)" >&2; exit 1 ;;
  esac
}

NATIVE="$(host_target)"
echo "编本机架构（$NATIVE）…"
dart build cli
[[ -x "build/cli/$NATIVE/bundle/bin/ishkafel" ]] || {
  echo "没找到产物：build/cli/$NATIVE/bundle/bin/ishkafel" >&2; exit 1
}

OTHER=""
if [[ "$NATIVE" == "macos_arm64" ]]; then OTHER="macos_x64"; else OTHER="macos_arm64"; fi

BUNDLE="build/cli/$NATIVE/bundle"
UNIVERSAL=0

if [[ -x "$DART_X64" && "$NATIVE" == "macos_arm64" ]]; then
  echo "编另一个架构（$OTHER，走 Rosetta）…"
  # 用 x64 的 Dart 编一遍。它会把产物放进 build/cli/macos_x64/
  arch -x86_64 "$DART_X64" build cli
  if [[ -x "build/cli/$OTHER/bundle/bin/ishkafel" ]]; then
    OUT="build/cli/universal/bundle"
    rm -rf "$OUT"
    mkdir -p "$OUT/bin" "$OUT/lib"
    lipo -create "build/cli/$NATIVE/bundle/bin/ishkafel" \
                 "build/cli/$OTHER/bundle/bin/ishkafel" \
         -output "$OUT/bin/ishkafel"
    chmod 755 "$OUT/bin/ishkafel"
    for dylib in build/cli/"$NATIVE"/bundle/lib/*; do
      name="$(basename "$dylib")"
      lipo -create "$dylib" "build/cli/$OTHER/bundle/lib/$name" \
           -output "$OUT/lib/$name"
    done
    BUNDLE="$OUT"
    UNIVERSAL=1
    echo "已合成 universal：$(lipo -info "$OUT/bin/ishkafel" | sed 's/.*are: //')"
  else
    echo "x64 那次没出产物，跳过合成" >&2
  fi
fi

if [[ "$UNIVERSAL" == 0 ]]; then
  MSG="只编出了 $NATIVE 一个架构。要 universal 需要一份 x64 的 Dart SDK：
  1. 下载（国内源）：
     https://storage.flutter-io.cn/dart-archive/channels/stable/release/\$(dart --version 里的版本)/sdk/dartsdk-macos-x64-release.zip
  2. 解压到 ~/sdk/dart-sdk-x64（或用 ISHKAFEL_DART_X64 指到它的 bin/dart）
  3. 重跑本脚本"
  if [[ "$REQUIRE_UNIVERSAL" == 1 ]]; then
    echo "$MSG" >&2
    exit 1
  fi
  echo "$MSG" >&2
fi

# 用包装脚本而不是软链：bundle 里的可执行文件要靠相对路径找 dylib，
# 软链过去会让它找不到
cat > build/ishkafel <<SHIM
#!/usr/bin/env bash
exec "\$(dirname "\$0")/${BUNDLE#build/}/bin/ishkafel" "\$@"
SHIM
chmod +x build/ishkafel

echo "好了：build/ishkafel  →  $BUNDLE/bin/ishkafel"

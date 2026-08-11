#!/usr/bin/env bash
# 构建 CLI，并在 build/ishkafel 放一个方便调用的入口。
#
# 为什么不是 `dart compile exe`：media_kit 的传递依赖 objective_c 带 build
# hooks，`dart compile` 不支持这个组合，会直接报错让你改用 `dart build`。
#
# 注意产物是**一个 bundle 目录**（可执行文件 + objective_c.dylib），不是单
# 文件；而且路径里带架构（macos_arm64）。要发给别的机器得整个目录一起带。
set -euo pipefail
cd "$(dirname "$0")/.."

dart build cli

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) TARGET="macos_arm64" ;;
  x86_64) TARGET="macos_x64" ;;
  *) echo "不认识的架构：$ARCH" >&2; exit 1 ;;
esac

BUNDLE="build/cli/$TARGET/bundle"
if [[ ! -x "$BUNDLE/bin/ishkafel" ]]; then
  echo "没找到产物：$BUNDLE/bin/ishkafel" >&2
  exit 1
fi

# 用包装脚本而不是软链：bundle 里的可执行文件要靠相对路径找 dylib，
# 软链过去会让它找不到
cat > build/ishkafel <<SHIM
#!/usr/bin/env bash
exec "\$(dirname "\$0")/cli/$TARGET/bundle/bin/ishkafel" "\$@"
SHIM
chmod +x build/ishkafel

echo "好了：build/ishkafel  →  $BUNDLE/bin/ishkafel"

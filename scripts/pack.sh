#!/usr/bin/env bash
# 打一个可以发出去的新包：版本号 +1 → 构建 → 打 zip。
#
#   ./scripts/pack.sh
#
# 版本号每次自增，是为了让手上并存的几个包能分清。「关于」页显示的版本号是
# 排查问题时唯一的对齐锚点——同事发来一张截图，光看界面猜不出他装的是哪一版
# （真机上误判过一次：以为功能没打进包，其实是他装的旧包）。
set -euo pipefail
cd "$(dirname "$0")/.."

# 更新说明要在**自增之前**检查。放在后面的话，一次打包失败就白烧掉一个版本号，
# 下次重跑又 +1——真发生过，连跳两个版本，而这两个号谁也没拿到过
CURRENT="$(grep '^const String appVersion' lib/core/app_version.dart \
  | sed "s/.*'\(.*\)'.*/\1/")"
NEXT="$(echo "$CURRENT" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')"
if ! grep -q "^## ${NEXT}\b" CHANGELOG.md; then
  echo "CHANGELOG.md 里没有 ${NEXT} 这一节——先补上再打包。" >&2
  echo "（这一版要发给别人，对方得知道改了什么。在文件顶上加一节 '## ${NEXT}'）" >&2
  exit 1
fi

# CLI 冒烟：**必须在版本号自增之前**。
#
# 选项重名这类错误 `flutter analyze` 和单测都发现不了——ArgParser 是运行期
# 才抛 Duplicate option，而后果是整个 CLI 一执行就崩。package_macos.sh 末尾
# 确实会真跑一次，但那时版本号已经加过了：2026-09-07 就这么白烧掉一个 0.1.186
# （上面那段注释担心的正是这件事，只是当时只防住了 CHANGELOG 那一半）。
if ! dart run bin/ishkafel.dart --help > /dev/null 2>&1; then
  echo "命令行工具起不来，先修好再打包：" >&2
  dart run bin/ishkafel.dart --help >&2 || true
  exit 1
fi

./scripts/bump_build.sh
./scripts/build_macos.sh --release
./scripts/package_macos.sh

# **打包不等于上线。**
#
# 打包是出一个产物，随时可以做、做多少次都行；上线是把这一版推到线上，
# 所有人下次打开就会看到更新提示——那是对外的动作，要人点头才做。
# 每改一行就自动往所有人机器上推一版，是不对的。
if [ -f .secrets/update_tos_ak_write ]; then
  echo
  echo "包已打好，**还没上线**。要让大家更新到这一版，跑："
  echo "  ./scripts/publish.sh"
fi

# 打完包顺手把跑着的换成新版本。
#
# **不能只 open**：macOS 对已经在跑的 app 只是激活窗口、不加载新二进制，
# 于是「新功能没生效」——真机上撞过好几次，用户只好自己退出再打开一遍。
# --no-restart 给不需要立刻看效果的场合（比如只是出包发给别人）
if [ "${1:-}" != "--no-restart" ]; then
  ./scripts/restart_app.sh
fi

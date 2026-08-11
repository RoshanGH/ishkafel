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

./scripts/bump_build.sh
./scripts/build_macos.sh --release
./scripts/package_macos.sh

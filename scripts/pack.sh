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
CURRENT="$(grep '^const String appVersion' lib/features/settings/settings_providers.dart \
  | sed "s/.*'\(.*\)'.*/\1/")"
NEXT="$(echo "$CURRENT" | awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}')"
if ! grep -q "^## ${NEXT}\b" CHANGELOG.md; then
  echo "CHANGELOG.md 里没有 ${NEXT} 这一节——先补上再打包。" >&2
  echo "（这一版要发给别人，对方得知道改了什么。在文件顶上加一节 '## ${NEXT}'）" >&2
  exit 1
fi

./scripts/bump_build.sh
./scripts/build_macos.sh --release
./scripts/package_macos.sh

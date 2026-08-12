#!/usr/bin/env bash
# 版本号自增：0.1.0 → 0.1.1 → 0.1.2 …
#
# 为什么要有它：手上同时躺着好几个包，界面长得又一样，分不清哪个是哪个。
# 「关于」页显示的版本号是排查问题时唯一的对齐锚点——同事发来一张截图，
# 光看界面猜不出他装的是哪一版（真机上就这么误判过一次，以为功能没打进包，
# 其实是他装的旧包）。
#
# 三处必须同时改，有测试盯着它们不漂移：
#   pubspec.yaml            version: x.y.z+build
#   settings_providers.dart const appVersion
#   （打包脚本按 appVersion 命名产物）
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="lib/core/app_version.dart"
CURRENT="$(grep '^const String appVersion' "$SRC" | sed "s/.*'\(.*\)'.*/\1/")"
MAJOR="${CURRENT%%.*}"
REST="${CURRENT#*.}"
MINOR="${REST%%.*}"
PATCH="${REST#*.}"
NEXT="$MAJOR.$MINOR.$((PATCH + 1))"

# pubspec 的 +N 是构建号，一并加一
BUILD="$(grep '^version:' pubspec.yaml | sed 's/.*+//')"
NEXT_BUILD=$((BUILD + 1))

sed -i '' "s/^const String appVersion = '.*';/const String appVersion = '$NEXT';/" "$SRC"
sed -i '' "s/^version: .*/version: $NEXT+$NEXT_BUILD/" pubspec.yaml

echo "版本号 ${CURRENT} → ${NEXT}  构建号 ${BUILD} → ${NEXT_BUILD}"

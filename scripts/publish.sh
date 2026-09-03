#!/usr/bin/env bash
# **上线**：把已经打好的这一版推到线上，所有人下次打开就会看到更新提示。
#
#   ./scripts/publish.sh          # 会先问一遍
#   ./scripts/publish.sh --yes    # 不问（脚本里调用时用）
#
# 和「打包」分开是有意的：打包是出产物，随时可以做；上线是对外的动作——
# 一旦推上去，所有人下次打开就会被提示更新，收不回来。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep '^const String appVersion' lib/core/app_version.dart \
  | sed "s/.*'\(.*\)'.*/\1/")"
ZIP="build/dist/ishkafel-${VERSION}.zip"

if [[ ! -f "$ZIP" ]]; then
  echo "没有 $ZIP —— 先跑 ./scripts/pack.sh 打包" >&2
  exit 1
fi

if [[ "${1:-}" != "--yes" ]]; then
  echo "要上线的是 ${VERSION}（$(du -h "$ZIP" | cut -f1)）"
  echo
  echo "这一版改了什么："
  awk -v v="## ${VERSION}" '$0 == v {on=1; next} on && /^## / {exit} on' \
    CHANGELOG.md | head -12 | sed 's/^/  /'
  echo
  echo "上线之后，所有装了 0.1.172 以上版本的人下次打开就会看到更新提示。"
  printf "确认上线？(y/N) "
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "没上线。"; exit 0 ;;
  esac
fi

dart run tool/publish_release.dart

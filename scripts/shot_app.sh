#!/usr/bin/env bash
# 给 app 窗口截图，不跟终端抢前台。
#
# 为什么不用「前台化再全屏截」：System Events 把 ishkafel 的窗口设成 AXMain
# 之后，屏幕上最上层仍然是终端（窗口在别的 Space 或被遮住），截出来是一屏
# 终端文字——真机上连着栽了三次，每次都以为界面没改动生效。
#
#   ./scripts/shot_app.sh /tmp/x.png
set -euo pipefail
OUT="${1:-/tmp/ishkafel-shot.png}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo(
  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
  if let owner = w[kCGWindowOwnerName as String] as? String, owner.contains("ishkafel"),
     let num = w[kCGWindowNumber as String] as? Int,
     let bounds = w[kCGWindowBounds as String] as? [String: Any],
     let h = bounds["Height"] as? Double, h > 200 {
    print(num)
  }
}
SWIFT
ID="$(swift "$WORK/winid.swift" | head -1)"
if [[ -z "$ID" ]]; then
  echo "没找到 ishkafel 的窗口——app 起来了吗？" >&2
  exit 1
fi
screencapture -x -o -l "$ID" "$OUT"
echo "$OUT"

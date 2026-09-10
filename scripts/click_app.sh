#!/usr/bin/env bash
# 按「窗口内坐标」点 app：截图上量到的 (x,y) 直接用，脚本自己换算成屏幕坐标。
#
# 为什么要有它：shot_app.sh 截的是窗口图，量出来的坐标是窗口内的；
# cliclick 要的是屏幕坐标。每次手算一遍窗口原点，迟早点歪——点歪了在
# 真实数据上就是误触（真机踩过：把 U1 的标签改成了「促单」）。
#
#   ./scripts/click_app.sh 127 267
set -euo pipefail
X="$1"; Y="$2"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/b.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo(
  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
  if let owner = w[kCGWindowOwnerName as String] as? String, owner.contains("ishkafel"),
     let b = w[kCGWindowBounds as String] as? [String: Any],
     let h = b["Height"] as? Double, h > 200 {
    print("\(b["X"]!) \(b["Y"]!)"); break
  }
}
SWIFT
# 先把窗口拿到前台，**再等它的位置稳定下来**：刚启动/刚激活那几百毫秒里
# 窗口还在做动画，这时读到的是中间态的 bounds（实测读到过 312,96 1296x822，
# 而真实位置是 240,47 1440x912）——按它算出来的坐标点在别的地方，
# 在真实数据上就是误触
osascript -e 'tell application "System Events" to tell process "ishkafel" to set frontmost to true' >/dev/null 2>&1 || true
last=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  now="$(swift "$WORK/b.swift")"
  if [[ -n "$now" && "$now" == "$last" ]]; then break; fi
  last="$now"
  sleep 0.25
done
read -r OX OY <<< "$last"
if [[ -z "${OX:-}" ]]; then echo "没找到 ishkafel 窗口" >&2; exit 1; fi
cliclick "c:$(python3 -c "print(int($OX+$X))"),$(python3 -c "print(int($OY+$Y))")"

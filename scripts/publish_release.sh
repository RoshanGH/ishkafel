#!/usr/bin/env bash
# 把打好的包发上去，让所有人能一键升级。
#
#   ./scripts/publish_release.sh            # 发当前版本
#
# 做两件事：
#   1. 上传 zip 到私有 bucket（包里带着明文 AI 凭据，绝不能公开读）
#   2. 生成并上传 latest.json（**公开读**，但里面只有版本号、指纹、更新说明，
#      没有下载地址——地址由 app 拿只读凭据现换预签名链接）
#
# 需要 .secrets/ 下这几个文件（和 build_macos.sh 用的是同一套）：
#   update_tos_region / update_tos_bucket / update_tos_endpoint
#   update_tos_ak / update_tos_sk          ← 这里用的是**可写**的那对
#   update_manifest_url                    ← 只用来打印，方便核对
set -euo pipefail
cd "$(dirname "$0")/.."
SECRETS=".secrets"

need() {
  local f="$SECRETS/$1"
  [[ -f "$f" ]] || { echo "缺少 $f" >&2; exit 1; }
  tr -d '[:space:]' < "$f"
}

VERSION="$(grep '^const String appVersion' lib/core/app_version.dart \
  | sed "s/.*'\(.*\)'.*/\1/")"
ZIP="build/dist/ishkafel-${VERSION}.zip"
[[ -f "$ZIP" ]] || { echo "没有 $ZIP —— 先跑 ./scripts/pack.sh" >&2; exit 1; }

REGION="$(need update_tos_region)"
BUCKET="$(need update_tos_bucket)"
ENDPOINT="$(need update_tos_endpoint)"
AK="$(need update_tos_ak_write)"
SK="$(need update_tos_sk_write)"

KEY="releases/ishkafel-${VERSION}.zip"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(stat -f%z "$ZIP")"

# 更新说明取 CHANGELOG 里这一版那一节——人点「更新」之前要看得到改了什么
NOTES="$(awk -v v="## ${VERSION}" '
  $0 == v {on=1; next}
  on && /^## / {exit}
  on {print}
' CHANGELOG.md)"

MANIFEST="build/dist/latest.json"
python3 - "$VERSION" "$KEY" "$SHA" "$SIZE" "$MANIFEST" <<'PY'
import json, sys
version, key, sha, size, out = sys.argv[1:6]
notes = sys.stdin.read() if not sys.stdin.isatty() else ''
json.dump({'version': version, 'objectKey': key, 'sha256': sha,
           'sizeBytes': int(size), 'notes': notes.strip()},
          open(out, 'w'), ensure_ascii=False, indent=2)
PY
# 上一步的 notes 走 stdin 会和 heredoc 打架，单独补进去
python3 - "$MANIFEST" <<PY
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['notes'] = """${NOTES}"""
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
PY

echo "版本 ${VERSION}"
echo "  包    ${ZIP}  $(du -h "$ZIP" | cut -f1)"
echo "  指纹  ${SHA}"
echo "  清单  ${MANIFEST}"
echo
echo "接下来用 TOS 命令行上传（凭据不经过这个脚本以外的地方）："
echo "  tosutil cp ${ZIP} tos://${BUCKET}/${KEY}"
echo "  tosutil cp ${MANIFEST} tos://${BUCKET}/latest.json -acl public-read"
echo
echo "注意：**包必须保持私有**，只有 latest.json 是公开读的。"
echo "产物里带着明文 AI 凭据，包一旦公开，谁拿到链接都能提出来烧钱。"

#!/usr/bin/env bash
# 打一个能拷到别的 Mac 上跑的包（universal：Apple Silicon + Intel 通用）。
#
#   ./scripts/package_macos.sh
#
# 产物：build/dist/ishkafel-<版本>.zip + 同目录一份「新机器上怎么跑起来」。
#
# 为什么用 ditto 而不是 zip：macOS 的 app 是个目录，里面有符号链接与扩展属性，
# 普通 zip 压完解出来签名就坏了，Finder 直接报「已损坏」。
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/macos/Build/Products/Release/ishkafel.app"
DIST="build/dist"

if [[ ! -d "$APP" ]]; then
  echo "还没有 Release 产物。先跑：./scripts/build_macos.sh --release" >&2
  exit 1
fi

# 架构自检：只有一个架构的包拷到另一种 Mac 上根本起不来（报 Bad CPU type），
# 而这件事直到对方双击那一刻才会暴露——必须在打包这一步挡住
ARCHS="$(lipo -info "$APP/Contents/MacOS/ishkafel" | sed 's/.*are: //;s/.*is architecture: //')"
if [[ "$ARCHS" != *"x86_64"* || "$ARCHS" != *"arm64"* ]]; then
  echo "产物不是 universal（当前：$ARCHS）——拷到另一种 Mac 上会起不来。" >&2
  echo "检查 Xcode 的 ARCHS 设置后重新构建。" >&2
  exit 1
fi
echo "架构自检通过：$ARCHS"

# 把命令行工具塞进 app 里。这样使用者装完 app 在设置里点一下就能用，
# 不需要知道自己这台是 Intel 还是 M 系列，更不需要自己去编译什么
echo "构建命令行工具（universal）…"
./scripts/build_cli.sh --require-universal
CLI_SRC="build/cli/dist"
# 两个架构的产物必须都在。少一个的话，那种机器的使用者点完「安装」敲命令
# 会得到「Bad CPU type」——而这件事要等包发出去才暴露
for want in macos_arm64 macos_x64; do
  if [[ ! -x "$CLI_SRC/$want/bundle/bin/ishkafel" ]]; then
    echo "命令行工具缺 $want 这个架构，别把这个包发出去。" >&2
    exit 1
  fi
done
echo "命令行工具自检通过：macos_arm64 + macos_x64"
rm -rf "$APP/Contents/Resources/cli"
mkdir -p "$APP/Contents/Resources/cli"
cp -R "$CLI_SRC/." "$APP/Contents/Resources/cli/"

# 把凭据也塞进去：`dart build cli` 不支持 --dart-define，GUI 那套编译期注入
# 对命令行工具完全无效。少了这一步，对方拿到包以后人点界面能跑、Agent 敲命令
# 却在第二步 analyze 就失败——而两者跑的是同一个 app（验收 Agent 真机撞上过）。
CRED_DST="$APP/Contents/Resources/cli/credentials"
rm -rf "$CRED_DST"
mkdir -p "$CRED_DST"
for key in ark_api_key speech_app_id speech_access_token; do
  src=".secrets/$key"
  if [[ ! -s "$src" ]]; then
    echo "缺 .secrets/$key——这个包里的命令行工具会没有凭据，Agent 跑不了分析。" >&2
    exit 1
  fi
  cp "$src" "$CRED_DST/$key"
  chmod 600 "$CRED_DST/$key"
done
echo "命令行工具的凭据已随包带上"
# 往签好名的 app 里塞东西有可能破坏封签，那样对方双击会报「已损坏」——
# 而这件事要等包发出去才暴露，必须在这儿挡住
if ! codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "塞进 CLI 之后 app 签名不过，重签一遍…"
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict "$APP" || {
    echo "重签之后签名仍然不过，别把这个包发出去。" >&2; exit 1
  }
fi
# 真的能跑起来吗——签名过了不代表二进制是好的
"$APP/Contents/Resources/cli/ishkafel" --help > /dev/null || {
  echo "app 里的命令行工具跑不起来，别把这个包发出去。" >&2; exit 1
}
# 凭据拷进去了 ≠ 工具找得到。它是从自己的路径往上回推 app 位置的，
# 而包里的真实布局（cli/<架构>/bundle/bin/）比单测里假设的深两层——
# 那一版单测全绿、装进包里 doctor 照样报「缺凭据」。所以在真包上跑一遍。
CRED_CHECK="$(cd /tmp && "$APP/Contents/Resources/cli/ishkafel" doctor 2>&1 || true)"
if grep -q "AI 凭据：缺" <<<"$CRED_CHECK"; then
  echo "包里的命令行工具读不到自己带的凭据，别把这个包发出去：" >&2
  grep "AI 凭据" <<<"$CRED_CHECK" >&2
  exit 1
fi
echo "命令行工具能读到随包带的凭据"

VERSION="$(grep '^const String appVersion' lib/core/app_version.dart \
  | sed "s/.*'\(.*\)'.*/\1/")"
mkdir -p "$DIST"
ZIP="$DIST/ishkafel-$VERSION.zip"

# 这一版的更新说明必须存在：包发出去而对方不知道改了什么，等于每次都要
# 靠猜。默认抽第一节（最新版本那一节）跟着包一起走。
#
# 对方手上不是上一版时（隔了好几个版本才发给他），用 --since <版本> 把
# 中间几节一并抽出来——他反馈的问题是在哪一版修的，他得看得到
SINCE=""
if [[ "${1:-}" == "--since" && -n "${2:-}" ]]; then
  SINCE="$2"
fi

CHANGES="$DIST/更新说明-$VERSION.md"
if ! grep -q "^## $VERSION\b" CHANGELOG.md; then
  echo "CHANGELOG.md 里没有 $VERSION 这一节——先补上再打包。" >&2
  echo "（版本号已经自增，直接在文件顶上加一节 '## $VERSION' 就行）" >&2
  exit 1
fi
if [[ -n "$SINCE" ]]; then
  if ! grep -q "^## $SINCE\b" CHANGELOG.md; then
    echo "CHANGELOG.md 里没有 $SINCE 这一节——--since 要给一个真实存在的版本。" >&2
    exit 1
  fi
  CHANGES="$DIST/更新说明-${SINCE}到${VERSION}.md"
  awk -v from="## $VERSION" -v to="## $SINCE" '
    $0 ~ "^" from "$" { on = 1 }
    on && $0 ~ "^" to "$" { exit }
    on { print }
  ' CHANGELOG.md > "$CHANGES"
else
  awk -v ver="## $VERSION" '
    $0 ~ "^" ver "$" { on = 1; print; next }
    on && /^## / { exit }
    on { print }
  ' CHANGELOG.md > "$CHANGES"
fi

# 只留这一份。同一个目录里躺着好几个版本、界面又长得一样，迟早发错——
# 今天就误判过一次：以为功能没打进包，其实是对方装的旧包
for old in "$DIST"/ishkafel-*.zip "$DIST"/更新说明*.md; do
  [[ -e "$old" ]] || continue
  [[ "$old" == "$ZIP" || "$old" == "$CHANGES" ]] && continue
  rm -f "$old"
  echo "清掉旧的：$(basename "$old")"
done

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

cat > "$DIST/新机器上怎么跑起来.md" <<'GUIDE'
# 在一台新的 Mac 上跑起来

这个包是 universal 的，Apple Silicon 与 Intel 都能跑。

## 1. 解压并放进「应用程序」

## 2. 去掉隔离属性（**必须做，否则打不开**）

这个包是 ad-hoc 签名的（没有 Apple Developer 账号）。凡是经网盘、微信、
AirDrop 传过来的 app 都会被打上隔离标记，双击会被系统拦下、甚至报「已损坏」。
在终端跑一次：

    xattr -dr com.apple.quarantine /Applications/ishkafel.app

跑完就能正常双击了，这一步只需要做一次。

## 3. 装三个外部命令行工具——**在 app 里点就行**

打开 app → 右上角设置 → 运行环境。没装的工具旁边会有「安装」按钮，点一下
就开始装，**下载走清华镜像**，安装过程逐行显示在下面（这些命令动辄几分钟，
看得见进度才知道还活着）。

| 工具 | 必需吗 | 说明 |
|---|---|---|
| ffmpeg / ffprobe | 必需 | 所有视频处理。需要机器上已有 Homebrew |
| miaoa CLI | 必需 | 检索素材、读标签组。官方脚本，自带平台判断 |
| audio-separator | 可选 | 只有「替换配乐」用得到。约 1GB，需要机器上已有 uv |

**Homebrew 与 uv 本身不代装**——那是系统级的东西，app 不该替你动。缺了的话
界面会直接告诉你先跑哪条命令（`brew install uv` 之类）。

如果你想手动装，命令是这三条（**注意镜像源，不加的话在国内基本装不上**）：

    # ffmpeg
    HOMEBREW_BOTTLE_DOMAIN=https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles \
    HOMEBREW_API_DOMAIN=https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api \
    HOMEBREW_NO_AUTO_UPDATE=1 brew install ffmpeg

    # miaoa CLI
    curl -fsSL https://miaoa.mininglamp.com/api/cli/install.sh | bash -s -- --host https://miaoa.mininglamp.com
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc

    # audio-separator（可选）
    UV_DEFAULT_INDEX=https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple \
    uv tool install "audio-separator[cpu]"

**miaoa 登录不用敲命令**：设置 → miaoa 账号 → 「登录 miaoa」，手机号收验证码
即可。登录状态存在这台电脑上（`~/.miaoa/`），所以每台机器都要各自登录一次。

⚠️ Intel Mac 上 audio-separator 没有 Metal 加速，同样一条片子可能要几分钟
（Apple Silicon 上约 15 秒）。首次使用还会自动下载约 700MB 的模型。

## 4. 想让 Agent 自己干活：装两样东西（可选）

设置 → 运行环境 → 命令行工具 → 「安装」。会弹一次系统授权框（要往
`/usr/local/bin` 写文件），点完之后在任意终端敲：

    ishkafel --help

**它随包一起走，Apple Silicon 与 Intel 通用**，不需要另外下载或编译任何东西。
有了它，Claude Code 这类 Agent 就能自己跑完导入、分析、挑素材、导出整条流程。

app 换过位置（比如从「下载」拖进「应用程序」）之后这条命令会失效，设置页里
会显示「需要重新安装」，点一下就好。

再往下一张卡片是「Agent 说明书」：点「复制全文」，粘给你的 Agent
（Claude Code、Codex、Cursor、Warp、各家桌面版都行），跟它说
「把这份技能装给你自己」。装好之后直接说一句：

> 用 ishkafel 把这条片子翻新一下

它就知道整套流程该怎么走了。要发给同事就「存成文件」，微信发过去即可。

## 5. 确认环境

打开 app → 设置 → 运行环境。这一页会把每个工具**实际解析到的路径**摆出来，
缺什么、装在哪，一眼就能看到。

## 数据放在哪

    ~/Library/Application Support/com.jichuang.ishkafel/ishkafel_data/

每台机器各自独立，不会跟着包走。任务、已下载的素材、预览代理都在这里；
设置里的「缓存管理」可以看占用和清理。
GUIDE

echo
echo "打好了：${ZIP}  $(du -h "$ZIP" | cut -f1)"
echo "说明：  ${DIST}/新机器上怎么跑起来.md"
echo "更新：  ${CHANGES}"

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

VERSION="$(grep '^const String appVersion' lib/features/settings/settings_providers.dart \
  | sed "s/.*'\(.*\)'.*/\1/")"
mkdir -p "$DIST"
ZIP="$DIST/ishkafel-$VERSION.zip"

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

## 4. 确认环境

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

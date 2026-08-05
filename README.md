# ishkafel

素材生产平台（成片翻新）：分析一条成片，按台词语义切分，从 miaoa 素材库检索
同标签素材替换画面，本地合成导出多条变体。

概念与流程见 [docs/术语表.md](docs/术语表.md) 与
[docs/2026-07-29-项目方向与架构设计.md](docs/2026-07-29-项目方向与架构设计.md)。

## 第一次在一台新机器上跑，要装什么

四样东西。装完**重启应用**——macOS 上由 Finder 启动的 GUI 进程继承的是
launchd 的空 PATH，应用只在启动时去那几个常见目录里找这些工具。

### 1. ffmpeg / ffprobe（必需）

抽帧、切片、合成成片都靠它。

```sh
brew install ffmpeg
```

### 2. miaoa CLI（必需）

素材库检索、标签体系、项目列表。装好后要登录一次：

```sh
miaoa auth login
```

登录失效时应用里会提示重新执行这条命令。

### 3. audio-separator（换配乐要用）

把原片音频拆成「纯人声口播」与「纯背景音」两条轨。**不装也能用**：分析照常
完成，只是替换配乐时新曲子会和原片自带的背景音叠在一起（应用里会说明）。

```sh
uv tool install "audio-separator[cpu]"
```

装完约 1GB；首次分析时会再自动下载分离模型（BS-Roformer，610MB）。之后每条
片子的分离约 80 秒，跑在分析流程里，不额外等待。

> 为什么用这个又大又慢的模型：更小更快的 MDX 系列（64MB / 15 秒）实测在口播
> 素材上分不干净，人声轨里明显留着背景音乐。这个判断只能靠听——RMS、频段能量
> 这些指标在几个模型之间的差异全在 -30dB 以下，完全测不出来。

### 4. AI 凭据（必需）

放在项目根目录的 `.secrets/`（已 gitignore），三个文件：

```
.secrets/ark_api_key           # 火山方舟：打标、语义切分、画面复核
.secrets/speech_app_id         # 语音技术：ASR、换音色合成
.secrets/speech_access_token
```

打包版从 `--dart-define` 注入，见 `scripts/build_macos.sh`；开发期从上面这个
目录读。凭据不全时应用照常启动，只是分析与打标不可用，并在界面上说明原因。

## 开发

```sh
flutter test          # 全量测试
flutter analyze
./scripts/build_macos.sh && open build/macos/Build/Products/Debug/ishkafel.app
```

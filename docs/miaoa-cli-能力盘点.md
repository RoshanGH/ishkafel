# miaoa CLI 能力盘点（对照 ishkafel 场景）

> 结论：**CLI 覆盖第一版全部所需场景，无需直接打 miaoa HTTP 接口。**
> 盘点日期：2026-07-29，CLI 版本 miaoa 0.3.0，SKILL.md 来自 https://miaoa.mininglamp.com/api/cli/skill.md

## 场景覆盖对照表

| ishkafel 场景 | CLI 命令 | 覆盖 | 实测备注 |
|---|---|---|---|
| 登录/租户/项目上下文 | `auth login/status`、`tenant select`、`project switch` | ✅ | 本机已有登录态（租户：极创美奥） |
| 拉标签组（受控词表） | `tag group list --scope tenant [--include-tags]` | ✅ | 分组带 `materialType`（VIDEO/STORYBOARD/…）和 `tagType`（AI / TENANT 自建）两类 |
| 拉组内标签 | `tag list --group <gid>` | ✅ | |
| 按标签检索候选素材 | `content search --type storyboard/video --public-tag 1,2 --public-mode and\|or` | ✅ | 公共/个人标签集合内 and/or 可选，集合间恒 AND |
| 按视频 ID 拉成片文件 | `content get <ID> --type video --json` → `mediaFile.url` | ✅ | 返回**带签名的 CDN 直链**，任意 HTTP 客户端可下载 |
| 素材画面描述 / 口播文本 | search/get 返回 `sceneDescription`、`voiceover`、`aiTags` 字段 | ✅ | storyboard 类型带这些字段 |
| 语义/向量检索（后置能力） | `content search --by content`（画面描述语义搜）、`--by voiceover`（旁白语义搜）、`--like-image`（以图搜图） | ✅ | 仅 storyboard（分镜库是唯一支持向量检索的库），比预期还强 |
| 素材入库+打标（二期，生产端） | `content upload --type storyboard`、`content tag set` | ✅ | storyboard 仅 mp4/mov，CLI 本地解析时长 |
| 成品回传需求池（可选） | `requirement output upload` | ✅ | VIDEO ≤500MB mp4/mov，单文件 |
| 云端 AI 视频拆解（备选参考） | `video-analysis upload/get` | ✅ | 异步任务，产出分镜段+描述，**不会自动入分镜库** |

## 关键实测发现与注意点

1. **签名 URL 有时效**：`mediaFile.url` 的 `sign=` 参数含过期时间戳（实测约数天有效期）。ishkafel 本地缓存素材时必须处理**过期重取**（按素材 ID 重新 `content get` 换新签名链接）。
2. **新入库素材有处理窗口期**：入库后打标运行中（`taggingStatus=RUNNING`）、`fileKey`/`url` 为 null，处理完成前拿不到下载链接。检索候选时应过滤或提示这类素材。
3. **标签组两类来源**：`tagType=AI`（平台预置，如「画面类型/画面动作/情绪氛围/脚本话术」）和 `tagType=TENANT`（租户自建，如「衣清.消毒液」）。ishkafel 的「选择标签组」功能两类都应展示。
4. **video（成片库）与 storyboard（分镜库）是两个库**：Web 端「成片库」对应 `--type video`；分镜片段在 `--type storyboard`。**替换用的候选素材主要来自分镜库**（有画面描述/口播/向量检索）；待翻新的原片从成片库按 ID 拉。
5. **JSON 模式**：所有命令加 `--json` 得到机器可读输出；失败也返回 JSON（`{"ok":false,"error":{...}}`）。退出码：0 成功 / 2 本地参数错误 / 1 后端业务错误。
6. **写操作纪律**（开发期用到时）：`content tag set --mode replace`、`canvas execute` 等默认 dry-run，须 `--confirm` 才真实写入；`content upload` 等一执行即提交，且有 MD5 硬去重。

## 对 ishkafel 架构的影响

- **开发期 / agent 驱动**：直接用 CLI（`--json`）即可完成全部 miaoa 交互，无需自己封装 HTTP 客户端。
- **产品运行期（待定）**：Flutter app 内与 miaoa 的通信可二选一：
  - a) 内置 miaoa CLI 二进制（同 ffmpeg 的打包方式），子进程 + JSON 解析——升级跟随 CLI，省开发
  - b) Dart 直接实现 HTTP 客户端——少一层进程依赖，但要自己维护接口适配
  - 倾向 a），待第一版开发时定夺。无论哪种，**每个使用者需自己登录 miaoa 账号**（短信验证码流程 CLI 已支持，可嵌入 app 登录界面）。
- **app 调 CLI 的可行性已确认**：CLI 不关心调用者身份（人 / agent / app 皆可），app 用子进程 `miaoa ... --json` 调用并解析 stdout 即可，与内置 ffmpeg 是同一种模式。
- **三平台二进制齐全**（已实测服务端可下载）：`miaoa-darwin-arm64` / `miaoa-windows-x64.exe`（约 3MB）/ `miaoa-linux-x64`，覆盖 ishkafel 的 Mac + Windows 打包需求；Intel Mac（Darwin-x86_64）**无**二进制，如有同事用 Intel Mac 需提前向 miaoa 侧提需求。

## 环境信息

- CLI 安装位置：`~/.local/bin/miaoa`（已加入 `~/.zshrc` 的 PATH）
- 配置：`~/.miaoa/config.json`（base_url=https://miaoa.mininglamp.com/api）
- skill 文档：`~/.openclaw/skills/miaoa-cli/SKILL.md`（868 行，来自服务端，勿手改；与 `--help` 冲突时以 `--help` 为准）

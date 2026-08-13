// 这个文件是**生成的**，别手改。
// 改 docs/AGENT_SKILL.md 之后跑：dart run tool/gen_agent_skill.dart
//
// 内嵌的理由见 tool/gen_agent_skill.dart 顶上的注释。

/// 给 Agent 的操作手册正文（来自 docs/AGENT_SKILL.md）
const String agentSkillMarkdown = r'''
# 用 ishkafel CLI 做成片翻新

给 Agent 看的操作手册。CLI 只提供**事实与保护**，「怎么挑得好」靠这份文档。
没有它，CLI 只是一堆能调用的动作，产不出能用的片子。

敲 `ishkafel` 说没这个命令的话：让使用者打开 app → 设置 → 运行环境 →
命令行工具 → 「安装」。它随 app 一起装好了，只是还没放进 PATH。

---

## 这个工具在做什么

拿一条已有的成片（原片），**保持台词与结构不变、把画面全换成新素材**，
产出若干条结构相同但画面全新的视频。

两层切分，别搞混：

| 术语 | 是什么 |
|---|---|
| **台词语义单元**（U） | 按台词语义切的段落。一段完整意思算一个，可能一句也可能几句 |
| **视觉镜头**（S） | 单元内部的画面切换。一个单元通常含多个镜头 |

替换有三种：整段换掉（`whole`）、只换其中某几个镜头（`perShot`）、
保留原片（`keepOriginal`）。

---

## 全流程

```bash
# 0. 看有哪些标签组（下一步要用它的 id）
ishkafel tag-groups

# 1. 建任务。标签组必须在这一步定
ishkafel import <视频路径> --tag-groups 396,365

# 2. 分析：抽音频 → ASR → 语义切分 → 镜头切点 → 打标
ishkafel analyze <task>

# 3. 看任务全貌，规划要换哪些
ishkafel task <task>

# 4. 逐个位置看候选（带上下文）
ishkafel candidates <task> --unit 1 --shot 5

# 5. 提交完整方案列表
ishkafel apply plans <task> --file plans.json

# 6. 导出（规格可选，缺省 1080P/30fps/推荐码率/H.264/mp4）
ishkafel export <task> --out ~/Desktop/成片 \
  [--resolution 480|720|1080|1440|2160] [--fps 24|25|30|50|60] \
  [--bitrate recommended|higher|lower|<kbps>] [--codec h264|hevc] [--format mp4|mov]
```

## 不用原片，从素材拼（空白任务）

没有参考成片、只知道要什么画面时走这条。分子手动加、标签手动填，
之后（候选、方案、导出）与上面完全同一条路：

```bash
ishkafel blank create --name 拼片A --tag-groups 1261   # 自带 4 个空分子
ishkafel blank tags <task> --unit 0 --tags 促单,痛点    # 标签必须在词表内
ishkafel blank add <task>                              # 加一个分子
ishkafel blank remove <task> --unit 4                  # 删一个（保底 4 个）
ishkafel candidates <task> --unit 0                    # 之后照旧
```

空白任务里每个分子都是整体替换：没有原始画面，`keepOriginal` 与 `perShot`
都不成立，方案里每个单元都要给 `whole` + material。`analyze` 对它无意义，
会直接拒绝。

任何一步都可以停下来交给人：

```bash
ishkafel open <task>    # 把 app 弹出来，落到这个任务的工作台
```

所有命令输出一行 JSON；失败时 `stderr` 是能直接照做的中文，退出码：
`2` 用法错误、`3` 找不到、`4` 被别人锁着。

---

## 语义切分和打标可以你自己做

第 2 步默认烧内置 API。加 `--external` 就把其中几步交给你——**这不是省钱的
开关，是让你能用上你的判断**：内置的那两步只看得到文字和时间，你能真的去看画面。

```bash
ishkafel analyze <task> --external=segment,tag
```

analyze 跑到该你做的地方就停下来，输出一件**待办**：它自带 `input`（你要的
全部输入）、`rules`（会被卡住的硬约束）、`shape`（回填格式的样例）、
`apply`（做完执行哪条命令）。照着做，然后：

```bash
ishkafel apply segment <task> --file seg.json    # 回填切分，接着吐下一件待办
ishkafel apply tags    <task> --file tags.json   # 回填标签
ishkafel todo <task>                             # 待办输出丢了，取回来
```

能外包的只有 `segment`（语义切分）和 `tag`（打标）。**ASR 不能**——它的
时间戳偏 200ms 就毁掉整条链，切分错位、镜头对不上，而且不报错，一路静默
到看成片才发现。写别的名字会直接报错，不会当作没写。

两条会被拦下来的硬约束，先知道比事后改快：

- **切分必须首尾相接、覆盖全部句子。** 用 `fromSentence`/`toSentence` 句子
  下标（含两端），别给台词文本——文本由句子拼出来，那是 ASR 的产出，不归你改
- **标签必须逐字命中 `vocabulary`。** 「厨房场景」和「厨房情景」在检索时是
  两回事，写错的一律拒收，不做近似匹配

**镜头标签必须看过画面再打。** 待办里给了 `sourcePath` 和每个镜头的
`sampleAtSec`（取的是镜头中点，两端常常正踩在转场上，抽出来是糊的）：

```bash
ffmpeg -ss <sampleAtSec> -i <sourcePath> -frames:v 1 -vf scale=180:-1 shot.jpg
```

51 个镜头就抽 51 张，拼成几张联系表一次看完，比一张一张看快得多。
光凭台词和时间戳猜画面里有什么，打出来的标签会把后面的检索带偏。

一批只错一条也整批不落——错误会一次全报出来，改完重交即可。

---

## 挑素材：这一节决定成片能不能用

### ① 标签组选错，后面全废

标签组是**按企业分的**。miaoa 当前企业不对 → `tag-groups` 列出来的是别的企业
的 → 打标没有受控词表 → 挑素材时没有标签可用。**这条链上没有任何一步会报错**。

`import` 时如果不给 `--tag-groups`，会警告但仍然建任务——那条任务是残废的，
别接着用。

### ② 必须看前后，否则「每个都对，连起来不对」

`candidates` 返回的 `context` 里有这些，**用它们**：

```json
{
  "slotMs": 2867,                    // 这个坑位多长
  "unitTranscript": "它虽然贵，但…",   // 这一段在讲什么
  "description": "向微波炉内壁喷洒清洁剂…",
  "previous": {"description": "手持喷雾瓶向镜头展示", "pickedMaterialIds": []},
  "next":     {"description": "台面上展示多瓶喷雾",   "pickedMaterialIds": [116719]}
}
```

人挑素材时是有整体感的——知道这里是开箱、那里是演示效果，所以不会在
「擦冰箱」后面接一个同类空镜。**你要做同样的事**：读台词知道这一段在说什么，
看前后镜头避免雷同或跳脱。

只按标签命中数挑，会得到一批**每一个都合规、连起来很怪**的片子。

### ③ 同一批素材常常几乎一样

素材库里经常是：1~5 号几乎一模一样（只有微小变化），6~10 又是另一批微调版。

**先看图再定**。`candidates` 给了 `thumbnailUrl`，读它。把明显同批的看作一个，
组方案时在**不同批之间**取，否则导出几十条片子看起来是同一条——而矩阵导出
的全部价值就在于变体之间有可见差异。

### ④ 时长要能对齐

候选比坑位长就要加速、短就要放慢，**只支持 0.8×~2.0×**。超出这个范围导出时
会被拒绝并点名。`candidates` 不返回时长（miaoa 的检索结果不含它），所以：
挑明显差异过大的素材前先掂量一下，或者留备选。

---

## 组方案：每一条都要能用

**同一条素材不能在一条方案里出现两次**——同一个画面在片子里出现两次，
一眼就能看出来。提交时会点名拒绝（如「素材 101 用了两次（U1 和 U2 的 S1）」）。
不同方案之间可以复用同一条素材。

**不做笛卡尔积。** 你提交的是一份完整方案列表，每条明确「U1 用什么、U2 用什么」。

为什么：笛卡尔积隐含「任意搭配都成立」，而上面第 ② 条说了那不成立。产品要求
是**产出的每一条都能用**，不是导 60 条挑 3 条。

```json
{
  "plans": [
    {
      "name": "A-厨房线",
      "units": [
        {"unit": 0, "mode": "whole", "material": 114799},
        {"unit": 1, "mode": "perShot", "shots": {"5": 116719}},
        {"unit": 2, "mode": "keepOriginal"}
      ]
    },
    {
      "name": "B-冰箱线",
      "units": [
        {"unit": 0, "mode": "whole", "material": 116833},
        {"unit": 1, "mode": "perShot", "shots": {"5": 116717}}
      ]
    }
  ]
}
```

规则：

- **没提到的单元自动保留原片**，不用显式写 `keepOriginal`
- `name` 必填且不能重名——它会成为导出文件名，重名会互相覆盖
- **方案之间要有可见差异**。两条方案只差一个三秒镜头，等于导了两条一样的片子
- 每条方案内部要前后顺畅（第 ② 条）

校验不过会**一次列出所有问题**，改完整批重提。

---

## 交给人审核

`ishkafel open <task>` 会把 app 弹出来落到工作台。人在那里能预览、能改、能自己
导出。

**注意锁**：你在操作时任务是锁着的，人打开会看到只读横幅；人可以强制接管，
之后你的写入会被拒绝。反过来，人正开着工作台时你的 `apply` / `export` 会返回
退出码 `4`——等它，或者让人先关掉。

锁会在持有者停止心跳 60 秒后自动失效，所以不会有永久卡死。

---

## 不要做的事

- **不要凭空造 id**。只能引用 `candidates` 返回过的素材 id、`task` 返回过的
  单元/镜头下标。校验会挡住，但那是在浪费一轮
- **不要替用户决定要不要导**。`export` 会先说「将导出 N 条到哪儿」，跑不跑
  是发起方的决定
- **不要在没有标签组的任务上硬挑**。先修标签组（切企业 → 重新 import）
- **不要绕过 CLI 直接改任务 JSON**。锁和校验都在 CLI 这一层，绕过去就没有保护了
''';

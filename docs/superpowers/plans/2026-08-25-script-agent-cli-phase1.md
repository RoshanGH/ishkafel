# 编导台 Agent CLI 实现计划（第一期：读 + 判断类回填）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Agent 能读懂一个脚本成片任务，并接管其中全部「选哪个」的判断——挑镜头、字幕断句、分时长、配段配乐——每一次回填都过校验才落盘。

**Architecture:** 沿用 `docs/superpowers/specs/2026-08-11-agent-cli-design.md` 已经定下的全部规矩（输出可验证性划线、任务锁、`--json`、非零退出 + 中文 stderr）。脚本成片与成片翻新是同一个 `RenewTask` 的两个字段（`units` / `script`），因此复用同一套仓库、锁、输出层，只在 `ishkafel script <子命令>` 下开一层新的命名空间。

**Tech Stack:** Dart（纯进程，不含 Flutter）、现有 `lib/core/script/*` 纯逻辑、`FileTaskRepository`、`TaskLockFile`。

## Global Constraints

- 所有回复、注释、提交信息用中文（项目既定）
- 每条命令都支持 `--json`；非零退出码表示失败，`stderr` 给**可直接展示的中文原因**，原始报文只进日志
- CLI 是纯 Dart 进程：**不得 import `package:flutter/*`**，也不得依赖 Flutter binding
- 数据目录与 GUI 完全一致：`~/Library/Application Support/com.jichuang.ishkafel/ishkafel_data`
- 不静默降级：影响结果的错误直接失败并点名（`CLAUDE.md` 最高准则）
- 锁必须能自愈：心跳超时 60 秒自动释放
- 文件 200–400 行为宜，800 行封顶
- **所有 `apply` 类命令：整批校验、整批拒绝、一次点全所有问题**——让调用方改一条提交一次是在浪费双方时间（沿用 `apply_command.dart` 既定风格）
- **写入一律走锁**：拿不到锁就非零退出并说明谁占着

---

## 划线：哪些步骤这一期开放给 Agent

依据是 spec 第三节的**输出可验证性**——能验证的才外包，不能验证的软件自己做。

| 步骤 | 输出 | 校验规则 | 这一期 |
|---|---|---|---|
| 挑镜头 | 候选素材 id 列表 | id 必须来自本次 `script shots` 给出的候选；素材可用时长 ≥ 分到的坑位 | ✅ |
| **字幕断句** | 切点（词序号）列表 | 严格递增、落在 `[1, 词数)`、不重复；每屏字数 ≤ 字号推出的上限 | ✅ |
| 时长分配 | 每镜毫秒数 | 总和 = 这一行的根（配音时长）；每镜 ≤ 素材可用量；每镜 ≥ 最小镜长 | ✅ |
| 配乐分段 | 行号区间 + 曲子 id | 区间连续且铺满全片、不重叠；曲子 id 来自 `script bgm` 候选 | ✅ |
| 提取脚本（ASR） | 文本 + 时间戳 | ❌ 无法验证，偏 200ms 静默毁掉整条链 | 不开放 |
| 配音（TTS） | 音频 | ❌ 无法验证 | 不开放 |
| 每屏改字 | 自由文本 | ⚠️ 无法验证「改得对不对」 | 不开放（见「不在这一期」） |

**字幕断句是这条线独有的价值点。** 现在软件里的 `autoScreenCuts` 是「标点优先 → 停顿次之 → 字数兜底」的启发式，本质是在猜断句；断句是纯语言判断，LLM 天然更强。而切点恰好完全可验证（三条约束一查即知），符合外包的判据。

---

## 文件结构

| 文件 | 职责 | 行数预估 |
|---|---|---|
| `lib/cli/script_view.dart` | 脚本任务 → JSON（全貌、单行详情）。只做投影，不含判断 | 260 |
| `lib/cli/script_shot_context.dart` | 某一行的候选镜头**上下文**：这一行台词、参考镜画面描述、相邻镜头已选什么、坑位多长 | 180 |
| `lib/cli/script_apply.dart` | 四类回填的**校验器**（纯函数，不碰 IO）：shots / subtitles / alloc / bgm | 380 |
| `lib/cli/commands/script_command.dart` | `ishkafel script <子命令>` 分发与参数解析 | 220 |
| `lib/cli/commands/script_apply_command.dart` | `script apply` 的 IO 编排：读文件 → 校验 → 持锁写入 → 留痕 | 200 |
| `docs/agent/SCRIPT_SKILL.md` | 给 Agent 的方法论（怎么挑得连贯、怎么断句像人念） | — |

校验器与 IO 分开是刻意的：**校验规则要能被单测钉死，不该被文件读写和锁缠住**。

---

### Task 0: GUI 在锁释放后自动重载（先做）

**排在最前是刻意的。** 锁与只读横幅在上一期（phase1 Task 4/5）已经做完了，
缺的只是最后一下：Agent 放锁之后，GUI 得把它改的东西载进来。这一条不做，
后面七个任务在「人在场」的场景下全是危险的——Agent 写得越多，被覆盖的越多。

场景（用户原话的用法）：人开着 GUI，让 Agent「把第 5 句换个镜头」。Agent 持锁 → GUI 只读 → Agent 写完放锁 → **GUI 里还是旧数据**。人随手改一下，自动保存把 Agent 刚做的活整个覆盖掉。

**Files:**
- Modify: `lib/features/director/director_page.dart`（锁状态监听 + 重载）
- Modify: `lib/core/storage/task_lock.dart`（如需要：暴露锁变化的通知）
- Test: `test/features/director/director_lock_reload_test.dart`

**Interfaces:**
- Consumes: `TaskLockFile.read()`（已有），加一个轮询（2 秒一次，与心跳同量级）

**行为契约：**

| 状态变化 | GUI 表现 |
|---|---|
| 无锁 → 有锁（别人拿走） | 切只读，顶部横幅「Agent 正在操作这个任务」 |
| 有锁 → 无锁（对方放锁） | **重新从磁盘读任务**，恢复可编辑，提示「Agent 改动已载入」 |
| 重载时本地有未落盘改动 | 先 `_flushNow()` 再读——本地改动优先落盘，避免自己的活丢了 |

**Steps:**

- [ ] **Step 1: 写失败的测试**

```dart
testWidgets('Agent 放锁后自动载入它的改动，不让人覆盖掉', (tester) async {
  // 打开任务 → 外部进程拿锁 → 改磁盘上的任务 → 放锁
  await pumpDirector(tester, wrap(repo, task));
  lock.acquire('Agent');
  await tester.pump(const Duration(seconds: 3));
  expect(find.textContaining('正在操作'), findsOneWidget);

  await repo.save(taskWithAgentEdit);   // Agent 写入
  lock.release('Agent');
  await tester.pump(const Duration(seconds: 3));

  expect(find.text('Agent 改动已载入'), findsOneWidget);
  expect(find.text('Agent 挑的镜头'), findsOneWidget,
      reason: '不重载的话，人再改一下就把 Agent 的活覆盖了');
});
```

- [ ] **Step 2-4: 跑测试 → 实现 → 真机验收**（两个终端：一个跑 CLI apply，一个开 GUI 看）
- [ ] **Step 5: 提交**

---

### Task 1: `ishkafel script show` —— 脚本任务全貌

Agent 干任何事之前先要能看懂这个任务。现在 `task_view.dart` 只投影成片翻新那部分（`units`），脚本任务在 CLI 里是**完全不可见**的。

**Files:**
- Create: `lib/cli/script_view.dart`
- Create: `lib/cli/commands/script_command.dart`
- Modify: `bin/ishkafel.dart`（注册 `script` 命令）
- Test: `test/cli/script_view_test.dart`

**Interfaces:**
- Produces:
  ```dart
  /// 脚本任务 → JSON。只做投影，不含任何判断
  Map<String, dynamic> scriptTaskJson(RenewTask task);

  /// 单行详情（`script show <task> --line <i>` 用）
  Map<String, dynamic> scriptLineJson(ScriptDoc doc, int index);
  ```
- Consumes: `RenewTask.script`（`ScriptDoc`）、`ShotAllocation.rootMsOf`、`ScriptLine.subtitleScreensAt`

**输出契约**（Agent 消费的就是这个，字段名不许随手改）：

```json
{
  "id": "hlhivnohoo",
  "seq": 2,
  "name": "脚本 08-19 18:37",
  "kind": "script",
  "refVideo": "/Users/…/参考片.mp4",
  "sourceVolume": 0.0,
  "totalMs": 128040,
  "lines": [
    {
      "index": 0,
      "id": "lmt0drx2w0",
      "type": "voiced",
      "text": "再不买就恢复69.9一瓶了。",
      "tags": ["促单"],
      "rootMs": 3048,
      "voice": {"state": "fresh", "voiceId": "zh_female_vv_uranus_bigtts",
                "durationMs": 3048, "hasWordTimings": true, "defect": null},
      "shots": [
        {"index": 0, "materialId": 105310, "name": "滴露_植源喷雾_…",
         "allocMs": 3048, "trimStartMs": 0, "speed": 1.0,
         "durationMs": 16300, "availableMs": 16300, "localSource": null,
         "sceneDescription": "在现代厨房中…"}
      ],
      "shortfallMs": 0,
      "reference": {
        "startMs": 0, "endMs": 3048,
        "shots": [{"index": 0, "startMs": 0, "endMs": 1200,
                   "description": "一只手举着喷雾瓶…", "tags": ["产品特写"],
                   "asr": "再不买就恢复"}]
      },
      "subtitle": {
        "manual": false,
        "maxCharsPerScreen": 15,
        "screens": [{"startMs": 0, "endMs": 3048, "text": "再不买就恢复69.9一瓶了"}]
      }
    }
  ],
  "bgm": [{"startLine": 0, "endLine": 12, "name": "快乐的尤克里里",
           "materialId": 883, "volume": 0.25}],
  "blocking": [
    {"lineIndex": 14, "shotIndex": 0, "kind": "shot-too-short",
     "message": "第 15 行第 1 镜的画面只有 1.2 秒，铺不满 6.0 秒"}
  ],
  "exports": [{"at": "2026-08-24T17:39:00", "path": "/Users/…/成片.mp4"}]
}
```

三个字段是**给 Agent 做判断用的，不能省**：

- `availableMs`：这条素材从取段点起、按当前倍速还能出多长成片。挑镜头和分时长都靠它
- `shortfallMs`：这一行还差多少没分出去（正数 = 画面没铺满）
- `blocking`：会**拦下预览与导出**的问题（画面铺不满、配音比画面短）。Agent 提交完必须自己复查这一项，不能等人打开 GUI 才发现

**Steps:**

- [ ] **Step 1: 写失败的测试**

```dart
// test/cli/script_view_test.dart
test('脚本任务全貌：行、配音、镜头、参考镜、字幕屏、配乐都投影出来', () {
  final task = _scriptTask(); // 一行、有配音有镜头有参考镜
  final json = scriptTaskJson(task);

  expect(json['kind'], 'script');
  final line = (json['lines'] as List).single as Map;
  expect(line['rootMs'], 3048, reason: '配音时长是这一行的根，Agent 分时长靠它');
  expect(line['voice']['hasWordTimings'], isTrue,
      reason: '没有逐字时间就不能外包断句——必须让调用方看得见');
  expect((line['shots'] as List).single['availableMs'], 16300,
      reason: '素材还能出多长，是挑镜头与分时长的前提');
  expect(line['reference']['shots'], hasLength(1));
  expect(line['subtitle']['maxCharsPerScreen'], 15,
      reason: '每屏字数上限由字号推出，断句要守这条');
});

test('画面铺不满的行进 blocking——Agent 提交完要能自查', () {
  final task = _taskWithShortShot(); // 素材 1.2s、坑位 6s
  final json = scriptTaskJson(task);
  final blocking = json['blocking'] as List;
  expect(blocking, hasLength(1));
  expect(blocking.single['kind'], 'shot-too-short');
});

test('没有脚本的任务不要冒充空脚本——如实说它不是脚本任务', () {
  expect(() => scriptTaskJson(_renewTaskWithoutScript()),
      throwsA(isA<ArgumentError>()));
});
```

- [ ] **Step 2: 跑测试确认失败**

```bash
flutter test test/cli/script_view_test.dart
```
Expected: FAIL — `scriptTaskJson` 未定义

- [ ] **Step 3: 实现 `script_view.dart`**

要点：
- `blocking` 复用 `shotCoverageGaps(doc)`（已存在于 `lib/core/script/shot_coverage.dart`），不要在 CLI 里写第二份判据
- `voice.defect` 复用 `ScriptLine.voiceDefectText`
- `subtitle.maxCharsPerScreen` 取 `(line.subtitleOverride ?? doc.subtitle).maxCharsPerScreen`
- `availableMs` 直接用 `LineShot.availableMs`
- 任务的 `script` 为 null 时抛 `ArgumentError('这不是脚本成片任务')`，由命令层翻成中文 stderr

- [ ] **Step 4: 实现 `script_command.dart` 的 `show` 分支并注册到 `bin/ishkafel.dart`**

```dart
Future<int> runScriptCommand({
  required List<String> rest,      // ['show', '<task>'] / ['shots', '<task>'] …
  required Directory dataDir,
  required String? file,           // --file（apply 用）
  required int? line,              // --line
  required bool json,
}) async { … }
```

- [ ] **Step 5: 跑测试确认通过 + 真机验收**

```bash
flutter test test/cli/script_view_test.dart
dart run bin/ishkafel.dart script show hlhivnohoo --json | jq '.lines[0].subtitle'
```

- [ ] **Step 6: 提交**

```bash
git add lib/cli/script_view.dart lib/cli/commands/script_command.dart bin/ishkafel.dart test/cli/script_view_test.dart
git commit -m "feat(cli): script show —— 脚本任务全貌投影给 Agent"
```

---
### Task 2: `ishkafel script shots` —— 候选镜头与上下文

Agent 挑镜头需要的不只是候选列表，还有**判断的依据**。spec 第九节说得很清楚：软件提供事实，方法论归 skill。所以这里要把「挑得好不好」所依赖的事实一次给全。

**Files:**
- Create: `lib/cli/script_shot_context.dart`
- Modify: `lib/cli/commands/script_command.dart`（`shots` 分支）
- Test: `test/cli/script_shot_context_test.dart`

**Interfaces:**
- Produces:
  ```dart
  /// 给第 [lineIndex] 行挑镜头时，Agent 需要知道的全部事实
  Map<String, dynamic> scriptShotContext(ScriptDoc doc, int lineIndex);
  ```
- Consumes: `LineRef.metaAt` / `segmentText`、`ShotAllocation.rootMsOf`、`LineShot.availableMs`

**输出契约：**

```json
{
  "lineIndex": 1,
  "text": "如果你觉得有点贵，那就趁现在活动赶紧买",
  "tags": ["促单"],
  "rootMs": 8880,
  "slotMs": 8880,
  "已选镜头": [],
  "reference": [
    {"index": 0, "startMs": 0, "endMs": 1600,
     "description": "镜头在厨房内，前景一只手拿着喷雾瓶",
     "tags": ["产品特写", "实拍"], "asr": "如果你觉得有点贵"}
  ],
  "neighbors": {
    "prev": {"lineIndex": 0, "shots": [{"materialId": 105310,
             "sceneDescription": "在现代厨房中，一只右手…"}]},
    "next": {"lineIndex": 2, "shots": []}
  },
  "usedElsewhere": [105310, 106720],
  "candidates": [
    {"materialId": 500123, "name": "滴露_冰箱清洁_…",
     "sceneDescription": "手持喷雾对冰箱隔板喷洒",
     "tags": ["冰箱玻璃板", "实拍"], "durationMs": 4900,
     "availableMs": 4900, "thumbnailUrl": "https://…",
     "matchedTags": 2}
  ]
}
```

四个字段是 skill 里那些方法论能落地的**前提**，缺一个 Agent 就只能瞎挑：

- `reference[].description`：参考片这一镜长什么样——**要复刻的就是它**
- `neighbors`：前后镜头是什么画面，避免「每个都对、连起来不对」
- `usedElsewhere`：整片已用的素材 id，避免几句话撞同一条
- `candidates[].availableMs`：能不能铺满这个坑位

**Steps:**

- [ ] **Step 1: 写失败的测试**

```dart
test('上下文给全：参考镜画面、前后镜头、已用素材、坑位长度', () {
  final doc = _docWithThreeLines(); // 第 0 行已挑镜头、第 1 行待挑
  final ctx = scriptShotContext(doc, 1);

  expect(ctx['slotMs'], 8880, reason: '坑位多长决定素材够不够铺');
  expect((ctx['reference'] as List).single['description'],
      contains('喷雾瓶'), reason: '要复刻的就是参考片这一镜');
  expect(ctx['neighbors']['prev']['shots'], hasLength(1),
      reason: '前后是什么画面，决定连起来顺不顺');
  expect(ctx['usedElsewhere'], contains(105310),
      reason: '整片已用的要避开，否则几句话撞同一条');
});

test('参考镜还没打标：如实说没有，不要编一个描述', () {
  final ctx = scriptShotContext(_docWithUntaggedRef(), 0);
  expect((ctx['reference'] as List).single['description'], isEmpty);
  expect(ctx['hint'], contains('参考镜还没打标'),
      reason: '没有依据要说出来，让调用方知道该先打标');
});

test('首尾行的相邻给 null 而不是编一个', () {
  final ctx = scriptShotContext(_docWithThreeLines(), 0);
  expect(ctx['neighbors']['prev'], isNull);
});
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现 `script_shot_context.dart`**

只做投影与拼装，**不做任何排序或推荐**——spec 第八节明确不做推荐，那是 Agent 的判断。

- [ ] **Step 4: 命令层接上真实检索**

`script shots <task> --line <i>` 的候选来自 miaoa，按**与 GUI 完全同一条路**取：
参考镜打过标 → `searchByDescription(参考镜描述, tagIds: 参考镜标签)`；
没打标 → 只返回上下文与 `hint`，候选为空并说明「先打标」。

**绝不退回拿台词搜画面描述**——那个错配刚在 0.1.45 里砍掉，CLI 不许把它捡回来。

- [ ] **Step 5: 真机验收**

```bash
dart run bin/ishkafel.dart script shots hlhivnohoo --line 1 --json | jq '.candidates | length'
dart run bin/ishkafel.dart script shots hlhivnohoo --line 1 --json | jq '.neighbors'
```

- [ ] **Step 6: 提交**

---

### Task 3: `ishkafel script apply shots` —— 回填挑镜结果

**Files:**
- Create: `lib/cli/script_apply.dart`（本任务只写 shots 校验器）
- Create: `lib/cli/commands/script_apply_command.dart`
- Test: `test/cli/script_apply_shots_test.dart`

**Interfaces:**
- Produces:
  ```dart
  /// 一条校验失败：面向调用方的中文原因 + 定位
  typedef ApplyIssue = ({int? lineIndex, int? shotIndex, String message});

  /// 校验挑镜提交。空列表 = 通过。**纯函数，不碰 IO**
  List<ApplyIssue> validateShotsSubmission({
    required ScriptDoc doc,
    required List<ShotPick> picks,
    required Set<int> offeredIds,   // 本次 script shots 给出过的候选
  });

  /// 一行的挑镜结果
  typedef ShotPick = ({int lineIndex, List<int> materialIds});
  ```

**提交格式**（`--file` 指向的 JSON）：

```json
{"picks": [{"lineIndex": 1, "materialIds": [500123, 500456]}]}
```

**校验规则**（每一条都要有对应测试）：

| 规则 | 不合格时的中文原因 |
|---|---|
| `lineIndex` 在范围内 | `第 N 行不存在（脚本共 M 行）` |
| 该行是配音行 | `第 N 行是画面行，镜头由时长决定，不走这里` |
| `materialIds` 非空 | `第 N 行没给镜头——不想配就别提交这一行` |
| id 来自本次候选 | `第 N 行的素材 500999 不在候选里——只能从 script shots 给出的候选里选` |
| 素材总可用量 ≥ 行的根 | `第 N 行的镜头加起来只能出 4.2 秒，铺不满 8.9 秒的配音` |
| 同一 id 不在同一行重复 | `第 N 行重复选了同一条素材 500123` |

**Steps:**

- [ ] **Step 1: 写失败的测试**

```dart
test('全部合法：放行', () {
  expect(validateShotsSubmission(doc: doc, picks: [(lineIndex: 1, materialIds: [500123])],
      offeredIds: {500123}), isEmpty);
});

test('选了候选之外的 id：拒绝并点名', () {
  final issues = validateShotsSubmission(doc: doc,
      picks: [(lineIndex: 1, materialIds: [999])], offeredIds: {500123});
  expect(issues.single.message, contains('不在候选里'));
});

test('镜头凑不满这一行：拒绝并说清差多少', () {
  // 候选只有 4.2 秒，行的根是 8.9 秒
  final issues = validateShotsSubmission(doc: shortDoc, picks: shortPicks,
      offeredIds: shortIds);
  expect(issues.single.message, allOf(contains('4.2'), contains('8.9')));
});

test('一次点全所有问题，不是遇到第一条就返回', () {
  final issues = validateShotsSubmission(doc: doc, picks: [
    (lineIndex: 99, materialIds: [500123]),
    (lineIndex: 1, materialIds: [999]),
  ], offeredIds: {500123});
  expect(issues, hasLength(2), reason: '让调用方改一条提交一次是在浪费双方时间');
});
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现校验器**

- [ ] **Step 4: 实现命令层 IO 编排**

顺序不许变：**读文件 → 校验 → 拿锁 → 重读任务 → 再校验一次 → 写入 → 留痕 → 放锁**。

第二次校验不是多余的：拿锁期间人可能在 GUI 里改过这个任务，第一次校验时的候选与坑位可能已经不成立了。

写入时**必须跟着分配时长**（`ShotAllocation.distribute` + `fillBySlowdown`），否则 `allocMs` 为 null，这一行进不了预览也导不出。

- [ ] **Step 5: 留痕**

按 spec 第七节，写进任务：谁做的（`agent`）、什么时候、提交了哪几行。

- [ ] **Step 6: 真机验收**

```bash
echo '{"picks":[{"lineIndex":1,"materialIds":[500123]}]}' > /tmp/picks.json
dart run bin/ishkafel.dart script apply shots hlhivnohoo --file /tmp/picks.json
dart run bin/ishkafel.dart script show hlhivnohoo --json | jq '.lines[1].shots'
```

- [ ] **Step 7: 提交**

---
### Task 4: `ishkafel script subtitles` —— 断句材料（这一期的重点）

**为什么这一步值得外包**：现在的 `autoScreenCuts` 是「标点优先 → 停顿次之 → 字数兜底」的启发式，本质是在猜断句。而断句是纯语言判断——哪儿断一口气、哪几个字该连在一起念，LLM 比规则强得多。切点又完全可验证（词序号，三条约束一查即知），完全符合 spec 的外包判据。

**Files:**
- Modify: `lib/cli/script_view.dart`（加 `scriptSubtitleMaterial`）
- Modify: `lib/cli/commands/script_command.dart`（`subtitles` 分支）
- Test: `test/cli/script_subtitle_material_test.dart`

**Interfaces:**
- Produces:
  ```dart
  /// 断句要用的全部材料：逐字时间戳、当前切点、字数上限
  Map<String, dynamic> scriptSubtitleMaterial(ScriptDoc doc, int lineIndex);
  ```

**输出契约：**

```json
{
  "lineIndex": 14,
  "text": "现在我们家每个月都有定期清理冰箱的好习惯，不然里面的食物只会越放越脏。",
  "lineSpanMs": 6048,
  "maxCharsPerScreen": 15,
  "hasWordTimings": true,
  "words": [
    {"index": 0, "text": "现", "startMs": 330, "endMs": 490},
    {"index": 1, "text": "在", "startMs": 490, "endMs": 690}
  ],
  "shotBoundaries": [{"shotIndex": 0, "startMs": 0, "endMs": 6048}],
  "current": {"manual": false, "cuts": [8, 18, 26],
              "screens": [{"startMs": 0, "endMs": 1490, "text": "现在我们家每个月都有"}]}
}
```

**必须带上 `shotBoundaries` 的理由**：屏与镜头是两条独立的线（这是 0.1.37 定下的模型），但一屏正好跨在两个镜头的接缝上时，观感是「字幕在画面切换的瞬间换了一半」。这个事实要给出来，**但要不要避让由 Agent 判断**——软件不替它决定。

**`hasWordTimings` 为 false 时**：这一行没有逐字时间（早期生成的配音），切点无从谈起。此时命令**非零退出**并说明「这句配音没有逐字时间，重新生成配音后才能断句」——不给一份假材料让它算。

**Steps:**

- [ ] **Step 1: 写失败的测试**

```dart
test('断句材料给全：逐字时间、字数上限、当前切点、镜头接缝', () {
  final m = scriptSubtitleMaterial(_docWithTimedVoice(), 0);
  expect(m['hasWordTimings'], isTrue);
  expect((m['words'] as List).first['index'], 0,
      reason: '切点是词序号，序号必须显式给出，不能让调用方自己数');
  expect(m['maxCharsPerScreen'], 15);
  expect(m['shotBoundaries'], isNotEmpty,
      reason: '一屏跨在画面切换处观感差——事实给出来，避不避让由它判断');
});

test('没有逐字时间：拒绝出材料，说清怎么办', () {
  expect(() => scriptSubtitleMaterial(_docWithoutWordTimings(), 0),
      throwsA(predicate((e) => '$e'.contains('重新生成配音'))));
});
```

- [ ] **Step 2-3: 跑测试 → 实现**

- [ ] **Step 4: 真机验收**

```bash
dart run bin/ishkafel.dart script subtitles hlhivnohoo --line 14 --json | jq '.words | length'
```

- [ ] **Step 5: 提交**

---

### Task 5: `ishkafel script apply subtitles` —— 回填断句

**Files:**
- Modify: `lib/cli/script_apply.dart`（加 subtitles 校验器）
- Test: `test/cli/script_apply_subtitles_test.dart`

**Interfaces:**
- Produces:
  ```dart
  /// 校验断句提交。空列表 = 通过
  List<ApplyIssue> validateSubtitleSubmission({
    required ScriptDoc doc,
    required List<SubtitleCuts> submissions,
  });

  typedef SubtitleCuts = ({int lineIndex, List<int> cuts});
  ```

**提交格式：**

```json
{"subtitles": [{"lineIndex": 14, "cuts": [8, 18, 26]}]}
```

切点的语义是「**从第 N 个词另起一屏**」，与 `SubtitleScreen.startWord` 一致。第 0 屏隐含从 0 开始，所以 `cuts` 里不写 0。

**校验规则：**

| 规则 | 不合格时的中文原因 |
|---|---|
| 该行有逐字时间 | `第 N 行的配音没有逐字时间，断不了句——重新生成配音后再来` |
| 严格递增 | `第 N 行的切点 [8, 18, 12] 不是递增的` |
| 落在 `[1, 词数)` | `第 N 行的切点 40 超出范围（这句共 33 个字）` |
| 不重复 | `第 N 行的切点 18 出现了两次` |
| 每屏 ≤ 字数上限 | `第 N 行第 2 屏有 22 个字，超过这个字号一屏能放的 15 个字——会出画` |
| 每屏非空 | `第 N 行第 3 屏一个字都没有` |
| 每屏 ≥ 4 个字 | `第 N 行第 2 屏只有 2 个字——闪一下就过去，看的人只会觉得晃眼` |

最后一条只在**有切点**时才可能触发，所以「哇塞！」这种整句两个字的短行不受
影响：它压根不需要切，`cuts` 是空的，一屏就是整行。被拦下的是「把一句话切出
一个两字屏」这种真正的坏切法。

**Steps:**

- [ ] **Step 1: 写失败的测试**

```dart
test('合法切点：放行，并落成人工切点（从此不跟自动走）', () {
  expect(validateSubtitleSubmission(doc: doc,
      submissions: [(lineIndex: 0, cuts: [8, 18])]), isEmpty);
});

test('切点超出范围：拒绝并说清这句有几个字', () {
  final issues = validateSubtitleSubmission(doc: doc,
      submissions: [(lineIndex: 0, cuts: [40])]);
  expect(issues.single.message, allOf(contains('40'), contains('33 个字')));
});

test('某一屏超过字数上限：拒绝——那会出画', () {
  final issues = validateSubtitleSubmission(doc: doc,
      submissions: [(lineIndex: 0, cuts: [30])]);  // 第一屏 30 字
  expect(issues.single.message, contains('会出画'));
});

test('切点挨着切出一个字的屏：拒绝', () {
  final issues = validateSubtitleSubmission(doc: doc,
      submissions: [(lineIndex: 0, cuts: [8, 9])]);
  expect(issues, isNotEmpty);
});

test('没有逐字时间的行：拒绝，不假装能断', () {
  final issues = validateSubtitleSubmission(doc: untimedDoc,
      submissions: [(lineIndex: 0, cuts: [5])]);
  expect(issues.single.message, contains('重新生成配音'));
});
```

- [ ] **Step 2-3: 跑测试 → 实现校验器**

- [ ] **Step 4: 写入**

落盘走 `ScriptLine.withSubtitleScreens([SubtitleScreen(startWord: 0), ...cuts.map(...)])`。
**这一行从此标记为「已手改」**（`subtitleScreens != null`），GUI 上会显示「已手改 / 恢复自动」——人一眼能看出这是 Agent 断的句，而且能一键退回。

- [ ] **Step 5: 真机验收**

```bash
echo '{"subtitles":[{"lineIndex":14,"cuts":[8,18,26]}]}' > /tmp/cuts.json
dart run bin/ishkafel.dart script apply subtitles hlhivnohoo --file /tmp/cuts.json
dart run bin/ishkafel.dart script show hlhivnohoo --json | jq '.lines[14].subtitle'
```

- [ ] **Step 6: 提交**

---
### Task 6: `ishkafel script apply alloc` —— 回填时长分配

一行分到几个镜头之后，每镜各占多久是**创作判断**：哪一镜该多停一会儿、哪一镜一带而过。软件现在只会均分再放慢充满，Agent 可以按台词的节奏分。

**Files:**
- Modify: `lib/cli/script_apply.dart`（加 alloc 校验器）
- Test: `test/cli/script_apply_alloc_test.dart`

**Interfaces:**
- Produces:
  ```dart
  List<ApplyIssue> validateAllocSubmission({
    required ScriptDoc doc,
    required List<AllocSubmission> submissions,
  });

  typedef AllocSubmission = ({int lineIndex, List<int> allocMs});
  ```

**提交格式：** `{"alloc": [{"lineIndex": 1, "allocMs": [1600, 2000, 1800, 1800, 1680]}]}`

**校验规则：**

| 规则 | 不合格时的中文原因 |
|---|---|
| 个数对得上 | `第 N 行有 5 个镜头，给了 4 个时长` |
| 总和 = 这一行的根 | `第 N 行加起来 8.5 秒，配音是 8.9 秒——差 0.4 秒会让画面与声音错位` |
| 每镜 ≤ 素材可用量 | `第 N 行第 3 镜要 2.4 秒，这条素材按当前倍速只能出 1.2 秒` |
| 每镜 ≥ 最小镜长 | `第 N 行第 2 镜只有 0.2 秒——比一眨眼还短` |

第二条是硬约束：`buildScriptTrackPlan` 里画面轨必须连续、声音轨必须等长（0.1.43 修的就是这个），差一点点就会让整条轨错位。

**Steps:**

- [ ] **Step 1: 写失败的测试**

```dart
test('总和不等于配音时长：拒绝并说清差多少', () {
  final issues = validateAllocSubmission(doc: doc,
      submissions: [(lineIndex: 1, allocMs: [1600, 2000])]);  // 少了 5.3 秒
  expect(issues.single.message, allOf(contains('8.9'), contains('错位')));
});

test('某一镜超过素材能出的长度：拒绝——成片里会定格', () {
  final issues = validateAllocSubmission(doc: doc,
      submissions: [(lineIndex: 1, allocMs: [6000, 2880])]);
  expect(issues.single.message, contains('只能出'));
});

test('容许 ±1 帧的取整零头', () {
  // 8880 拆成 [1600, 2000, 1800, 1800, 1681] —— 多 1ms，放行
  expect(validateAllocSubmission(doc: doc,
      submissions: [(lineIndex: 1, allocMs: [1600, 2000, 1800, 1800, 1681])]),
      isEmpty);
});
```

- [ ] **Step 2-4: 跑测试 → 实现 → 真机验收**

- [ ] **Step 5: 提交**

---

### Task 7: `ishkafel script bgm` / `apply bgm` —— 配乐分段

**Files:**
- Modify: `lib/cli/commands/script_command.dart`（`bgm` 分支）
- Modify: `lib/cli/script_apply.dart`（加 bgm 校验器）
- Test: `test/cli/script_apply_bgm_test.dart`

**`script bgm <task> [--keyword X]`** 返回配乐候选（复用 `BgmSearch`），带曲子 id、名称、时长；同时返回**当前分段**与每一行的时长，让 Agent 知道「这一段要放多久的曲子」。

**提交格式：** `{"bgm": [{"startLine": 0, "endLine": 12, "materialId": 883, "volume": 0.25}]}`

**校验规则：**

| 规则 | 不合格时的中文原因 |
|---|---|
| 区间连续铺满全片 | `第 13~14 行没有配乐段——配乐轨是整片切成几段，不能留空档` |
| 区间不重叠 | `第 10~14 行与第 12~20 行重叠了` |
| 行号在范围内 | `第 40 行不存在（脚本共 27 行）` |
| 曲子 id 有效 | `配乐 999 不在候选里` |
| 音量 0~1 | `音量 1.8 超出范围（0~1）` |

第一条沿用 `bgmRail` 的模型（0.1.36 定的：**整片被若干刀切成连续段、铺满全片**），不是「行区间随便标几段」。

**Steps:**

- [ ] **Step 1: 写失败的测试**（含「留空档要拒绝」这条）
- [ ] **Step 2-4: 跑测试 → 实现 → 真机验收**
- [ ] **Step 5: 提交**

---

### Task 8: 给 Agent 的 skill 文档

spec 第九节：**没有它，CLI 只是一堆能调用的动作，产不出能用的片子。** 这条线尤其如此——挑镜头和断句都是判断，判断需要方法论。

**Files:**
- Create: `docs/agent/SCRIPT_SKILL.md`
- Modify: `lib/cli/commands/skill_command.dart`（`ishkafel skill --install` 把它一起装到 agent 的 skill 目录）

**必须写进去的（每一条都来自这几版真机踩的坑）：**

1. **挑镜头**
   - 先看 `reference[].description`——**要复刻的是它**，不是台词字面
   - 看 `neighbors`，避免「每个都对、连起来不对」
   - 避开 `usedElsewhere`：同一批素材常有微调版（1~5 号几乎一样），几句话撞同一条会让片子看着像卡带
   - 看 `availableMs` 够不够铺满 `slotMs`——不够的话成片里会定格

2. **断句**（这一版的重点）
   - 一屏是一口气，不是一行字：按语义停顿断，不要按字数硬切
   - 数字、金额、单位不能拆开（「69.9 一瓶」不许在小数点断）
   - 一屏别少于 4 个字——闪一下就过去，看的人只会觉得晃眼
   - 别在画面切换的接缝上换屏（`shotBoundaries` 给了接缝位置）
   - 提交前自己按 `maxCharsPerScreen` 数一遍，超了会被拒

3. **分时长**：让重点镜头多停一会儿；总和必须严格等于配音时长

4. **读错误**：`apply` 是整批拒绝，一次会点全所有问题，照着改完再提交一次

5. **提交完要自查**：`script show` 的 `blocking` 必须是空的，否则这个片子导不出来

**Steps:**

- [ ] **Step 1: 写文档**
- [ ] **Step 2: 让 `ishkafel skill --install` 带上它**
- [ ] **Step 3: 真机验收——用一个空白 Agent 会话，只给它这份 skill 和 CLI，看能不能独立把一行的镜头挑对、句断对**
- [ ] **Step 4: 提交**

---

## 完成后的验收

这一期做完，下面这串应该在真机上一路跑通：

```bash
B=build/ishkafel
$B script show hlhivnohoo --json | jq '.lines | length'
$B script shots hlhivnohoo --line 1 --json | jq '.candidates | length'
$B script subtitles hlhivnohoo --line 14 --json | jq '.words | length'

echo '{"picks":[{"lineIndex":1,"materialIds":[500123]}]}' > /tmp/p.json
$B script apply shots hlhivnohoo --file /tmp/p.json
echo '{"subtitles":[{"lineIndex":14,"cuts":[8,18,26]}]}' > /tmp/c.json
$B script apply subtitles hlhivnohoo --file /tmp/c.json

$B script show hlhivnohoo --json | jq '.blocking'   # 必须是 []
```

并且：

- Agent 持锁期间 GUI 只读、横幅说明谁占着；**放锁后 GUI 自动载入 Agent 的改动**
- 任何一条 `apply` 提交非法数据都被整批拒绝，stderr 一次点全所有问题
- 每一次写入在任务里留痕：谁做的、什么时候、改了哪几行

## 不在这一期（进第二期）

- `script new` / `script extract` / `script voice` / `script export`——**执行类**动作。
  没有判断，实现快，但没有第一期它们只是遥控器
- **每屏改字**：输出是自由文本，「改得对不对」无法验证。要开放的话得先想清楚校验规则
  （只允许同音改写？只允许删字？）
- 配音音色的自动选择：可验证（音色 id 在目录内），但选得好不好没有判据，先不做
- MCP Server：等真有不会用 bash 的调用方（沿用 spec 第二节）
- 人与 Agent **同时编辑**同一任务：需要细粒度冲突检测，需求未被验证

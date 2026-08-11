# Agent CLI 第一期实现计划（骨架 · 只读 · 任务锁）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Agent 能用命令行读到任务全貌与候选素材（含上下文），并在需要人工审核时把 GUI 弹出来；同时用任务锁挡住「Agent 与人同时写坏同一份数据」。

**Architecture:** 新增纯 Dart 可执行入口 `bin/ishkafel.dart`，复用现有 `lib/core/`。为此先把 CLI 依赖树上的 core 文件从 `package:flutter/foundation.dart` 解耦（换成 `package:meta` / `package:collection` / `dart:isolate`）。任务锁作为文件写在任务目录下，GUI 与 CLI 共享同一份判定逻辑。

**Tech Stack:** Dart 3（`dart build cli`，见 Task 2 的坑）、`package:args`、`package:collection`、`package:meta`、`package:path`；测试用 `flutter test`（现有测试基建）。

## Global Constraints

- 所有回复、注释、提交信息用中文（项目既定）
- 每条命令都支持 `--json`；非零退出码表示失败，`stderr` 给**可直接展示的中文原因**，原始报文只进日志
- CLI 是纯 Dart 进程：**不得 import `package:flutter/*`**，也不得依赖 Flutter binding
- 数据目录与 GUI 完全一致：`~/Library/Application Support/com.jichuang.ishkafel/ishkafel_data`
- 不静默降级：影响结果的错误直接失败并点名（`CLAUDE.md` 最高准则）
- 锁必须能自愈：心跳超时 60 秒自动释放，否则持有者一崩任务就永久锁死
- 文件 200–400 行为宜，800 行封顶

---

### Task 1: 把 CLI 依赖树上的 core 文件与 Flutter 解耦

**Files:**
- Modify: `lib/core/log/app_log.dart`
- Modify: `lib/core/storage/file_task_repository.dart`
- Modify: `lib/core/models/export_record.dart`
- Modify: `lib/core/replacement/picked_material.dart`
- Modify: `lib/core/ffmpeg/media_spec.dart`
- Test: `test/core/no_flutter_in_cli_deps_test.dart`

**Interfaces:**
- Consumes: 无
- Produces: 上述文件不再 import `package:flutter/*`；`AppLog.sink`、`FileTaskRepository(Directory)`、`ExportRecord`、`PickedMaterial`、`MediaSpec` 的公开签名**一律不变**

- [ ] **Step 1: 写失败的测试——CLI 依赖树上不许出现 flutter**

创建 `test/core/no_flutter_in_cli_deps_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CLI 是纯 Dart 进程，没有 Flutter binding。这几个文件在 CLI 的依赖树上，
/// 一旦 import 了 package:flutter，编译 CLI 时直接失败（`dart build cli`）。
///
/// 用测试钉住而不是靠人记得：这类 import 常常是顺手加的（要个 @immutable
/// 就 import 了 foundation），而它坏掉的地方在另一个构建产物里。
void main() {
  const cliDependencies = [
    'lib/core/log/app_log.dart',
    'lib/core/storage/file_task_repository.dart',
    'lib/core/storage/task_repository.dart',
    'lib/core/models/export_record.dart',
    'lib/core/models/renew_task.dart',
    'lib/core/models/semantic_unit.dart',
    'lib/core/models/shot.dart',
    'lib/core/replacement/picked_material.dart',
    'lib/core/replacement/replacement_plan.dart',
    'lib/core/ffmpeg/media_spec.dart',
    'lib/core/ffmpeg/process_runner.dart',
  ];

  test('CLI 依赖树上的 core 文件不许 import flutter', () {
    final offenders = <String>[];
    for (final path in cliDependencies) {
      final file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path 不存在，清单该更新了');
      if (file.readAsStringSync().contains("package:flutter/")) {
        offenders.add(path);
      }
    }
    expect(offenders, isEmpty,
        reason: '这些文件在 CLI 依赖树上，import flutter 会让 dart build cli 失败');
  });
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/core/no_flutter_in_cli_deps_test.dart`
Expected: FAIL，offenders 列出 `app_log.dart`、`file_task_repository.dart`、`export_record.dart`、`picked_material.dart`、`media_spec.dart`

- [ ] **Step 3: 逐个替换**

`lib/core/log/app_log.dart` —— 删掉 `import 'package:flutter/foundation.dart';`，把 `installFlutterErrorForwarding` 整个方法移到新文件 `lib/app/flutter_error_bridge.dart`（那是 GUI 专属的），并在 `lib/main.dart` 改成从新路径 import。`AppLog` 只留 `sink` / `warn` / `info` / `_writeToStderr`。

`lib/core/storage/file_task_repository.dart` —— 把

```dart
import 'package:flutter/foundation.dart';
...
final payload = await compute(decodeTasksDirectory, _tasksDir.path);
```

换成

```dart
import 'dart:isolate';
...
// 解码不占调用方的 isolate：GUI 里是不跟渲染抢主 isolate，CLI 里是不阻塞
// 命令的其余部分。Isolate.run 是 compute 的纯 Dart 等价物
final payload = await Isolate.run(() => decodeTasksDirectory(_tasksDir.path));
```

`export_record.dart` / `picked_material.dart` / `media_spec.dart` —— 把
`import 'package:flutter/foundation.dart';` 换成 `import 'package:meta/meta.dart';`（它们只用了 `@immutable`）。

- [ ] **Step 4: 跑测试确认通过，并且没碰坏别的**

Run: `flutter test test/core/no_flutter_in_cli_deps_test.dart test/core/storage/ test/core/export/`
Expected: 全部 PASS。特别确认 `file_task_repository_test.dart` 里那条「解码不占用 UI isolate」仍然通过——它是这次替换唯一有行为风险的地方。

- [ ] **Step 5: 全量回归**

Run: `flutter analyze && flutter test`
Expected: analyze 无 issue；测试全绿

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "refactor: CLI 依赖树上的 core 文件脱离 Flutter

CLI 是纯 Dart 进程，没有 Flutter binding——依赖树上任何一个 import
package:flutter 都会让 dart build cli 直接失败。

替换都是等价物：@immutable → package:meta，compute → Isolate.run，
GUI 专属的 FlutterError 转发挪到 lib/app/。公开签名一个都没动。

用测试钉住这条约束：这类 import 常常是顺手加的（要个 @immutable 就
import 了 foundation），而它坏掉的地方在另一个构建产物里。"
```

---

### Task 2: CLI 入口骨架与数据目录定位

**Files:**
- Create: `bin/ishkafel.dart`
- Create: `lib/cli/data_dir.dart`
- Create: `lib/cli/cli_output.dart`
- Modify: `pubspec.yaml`（`args` 依赖）
- Test: `test/cli/data_dir_test.dart`
- Test: `test/cli/cli_output_test.dart`

**Interfaces:**
- Consumes: 无
- Produces:
  - `Directory resolveDataDir({Map<String,String>? env, String? override})` — 数据目录
  - `void emitJson(Object? payload, {IOSink? out})` — 打印 JSON 到 stdout
  - `Never failWith(String humanReason, {int code = 1, IOSink? err})` — 中文原因到 stderr 并退出
  - `const int exitBadUsage = 2;` `const int exitNotFound = 3;` `const int exitLocked = 4;`

- [ ] **Step 1: 写失败的测试**

创建 `test/cli/data_dir_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/data_dir.dart';

/// CLI 必须和 GUI 读同一个数据目录，否则「Agent 建的任务在 app 里看不见」。
/// GUI 走 path_provider（getApplicationSupportDirectory），CLI 没有 Flutter
/// binding，只能按同样的规则自己拼——这条规则在这里钉死。
void main() {
  test('默认落在 GUI 用的那个目录', () {
    final dir = resolveDataDir(env: {'HOME': '/Users/someone'});
    expect(
      dir.path,
      '/Users/someone/Library/Application Support/com.jichuang.ishkafel/ishkafel_data',
    );
  });

  test('允许显式覆盖——测试与多环境要用', () {
    final dir = resolveDataDir(env: {'HOME': '/Users/someone'}, override: '/tmp/x');
    expect(dir.path, '/tmp/x');
  });

  test('环境变量也能覆盖', () {
    final dir = resolveDataDir(
        env: {'HOME': '/Users/someone', 'ISHKAFEL_DATA_DIR': '/tmp/y'});
    expect(dir.path, '/tmp/y');
  });

  test('读不到 HOME 时明确失败，而不是拼出一个错的路径', () {
    expect(() => resolveDataDir(env: const {}), throwsA(isA<StateError>()));
  });
}
```

创建 `test/cli/cli_output_test.dart`：

```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';

void main() {
  test('JSON 一行输出，便于调用方按行读', () {
    final buffer = StringBuffer();
    emitJson({'ok': true, 'id': 'abc'}, out: buffer);
    expect(buffer.toString().trim().split('\n'), hasLength(1));
    expect(jsonDecode(buffer.toString()), {'ok': true, 'id': 'abc'});
  });

  test('中文不转义——报错要给人看', () {
    final buffer = StringBuffer();
    emitJson({'reason': '任务不存在'}, out: buffer);
    expect(buffer.toString(), contains('任务不存在'));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/cli/`
Expected: FAIL，`package:ishkafel/cli/data_dir.dart` 不存在

- [ ] **Step 3: 实现**

创建 `lib/cli/data_dir.dart`：

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

/// CLI 用的数据目录，必须与 GUI 完全一致。
///
/// GUI 走 `path_provider` 的 `getApplicationSupportDirectory()`，在 macOS 上
/// 就是 `~/Library/Application Support/<bundle id>`。CLI 没有 Flutter
/// binding，只能按同样规则自己拼——两边一旦不一致，就会出现「Agent 建的
/// 任务在 app 里看不见」这种最难查的问题。
const String bundleId = 'com.jichuang.ishkafel';

Directory resolveDataDir({Map<String, String>? env, String? override}) {
  final e = env ?? Platform.environment;
  final explicit = override ?? e['ISHKAFEL_DATA_DIR'];
  if (explicit != null && explicit.trim().isNotEmpty) {
    return Directory(explicit.trim());
  }
  final home = e['HOME'];
  if (home == null || home.trim().isEmpty) {
    // 拼一个错的路径会让 CLI 静默地在别处建任务，比直接失败难查得多
    throw StateError('读不到 HOME，无法定位数据目录；可用 ISHKAFEL_DATA_DIR 指定');
  }
  return Directory(
      p.join(home, 'Library', 'Application Support', bundleId, 'ishkafel_data'));
}
```

创建 `lib/cli/cli_output.dart`：

```dart
import 'dart:convert';
import 'dart:io';

/// 用法错误（参数不对）
const int exitBadUsage = 2;

/// 找不到（任务、单元、镜头）
const int exitNotFound = 3;

/// 被锁住了
const int exitLocked = 4;

/// 一行一个 JSON，调用方按行读就行。
///
/// 不缩进、不转义中文：这份输出是给程序读的，同时也要能被人一眼看懂——
/// `任务` 那种转义等于把报错藏起来。
void emitJson(Object? payload, {StringSink? out}) {
  (out ?? stdout).writeln(jsonEncode(payload));
}

/// 失败时把**能直接展示的中文**写到 stderr 并退出。
///
/// 原始异常报文进日志，不摊给调用方——见 CLAUDE.md：一句能照做的话
/// 比一句吓人的话有用。
Never failWith(String humanReason, {int code = 1, StringSink? err}) {
  (err ?? stderr).writeln(humanReason);
  exit(code);
}
```

创建 `bin/ishkafel.dart`：

```dart
import 'dart:io';

import 'package:args/args.dart';
import 'package:ishkafel/cli/cli_output.dart';

/// ishkafel 的命令行入口。
///
/// 存在的理由：让 Agent（Claude Code / Codex / 任何能跑 bash 的）驱动全流程。
/// 选 CLI 而不是 MCP Server 的理由见
/// `docs/superpowers/specs/2026-08-11-agent-cli-design.md` 第二节——
/// 决定性的一条是 Codex 用不了 MCP，而谁都能跑 bash。
Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('json', help: '输出结构化 JSON', defaultsTo: false)
    ..addOption('data-dir', help: '数据目录（默认与 app 一致）')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    failWith('${e.message}\n\n${_usage(parser)}', code: exitBadUsage);
  }

  if (parsed['help'] as bool || parsed.rest.isEmpty) {
    stdout.writeln(_usage(parser));
    exit(parsed.rest.isEmpty && !(parsed['help'] as bool) ? exitBadUsage : 0);
  }

  final command = parsed.rest.first;
  failWith('未知命令：$command\n\n${_usage(parser)}', code: exitBadUsage);
}

String _usage(ArgParser parser) => '''
ishkafel —— 成片翻新工具的命令行入口

用法：ishkafel <命令> [参数]

命令：
  （后续任务逐个接入）

通用参数：
${parser.usage}
''';
```

在 `pubspec.yaml` 的 `dependencies` 加上 `args: ^2.4.0`，并在文件末尾（顶层）加：

```yaml
executables:
  ishkafel: ishkafel
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter pub get && flutter test test/cli/`
Expected: PASS

- [ ] **Step 5: 确认能编译成独立二进制**

Run: `./scripts/build_cli.sh && build/ishkafel --help`
Expected: 编译成功；打印用法；退出码 0

这一步是 Task 1 的真正验收——只要还有 flutter import，这里会直接失败。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "feat(cli): 命令行入口骨架与数据目录定位

CLI 必须和 GUI 读同一个数据目录，否则会出现「Agent 建的任务在 app 里
看不见」这种最难查的问题。GUI 走 path_provider，CLI 没有 Flutter binding，
只能按同样规则自己拼——规则用测试钉死。

约定也在这一步定下来：所有命令 --json 输出一行 JSON（不转义中文，
程序要读、人也要能一眼看懂）；失败时 stderr 给可直接展示的中文，
退出码区分用法错误/找不到/被锁。

dart compile exe 跑通，同时也是上一个任务「脱离 Flutter」的真正验收。"
```

---

### Task 3: `ishkafel task <id>` —— 任务全貌

**Files:**
- Create: `lib/cli/commands/task_command.dart`
- Create: `lib/cli/task_view.dart`
- Modify: `bin/ishkafel.dart`
- Test: `test/cli/task_view_test.dart`

**Interfaces:**
- Consumes: `resolveDataDir`、`emitJson`、`failWith`、`exitNotFound`（Task 2）；`FileTaskRepository`、`RenewTask`（既有）
- Produces:
  - `Map<String, dynamic> taskToJson(RenewTask task)` — 任务的 JSON 视图
  - `Future<int> runTaskCommand({required List<String> rest, required Directory dataDir, StringSink? out, StringSink? err})`

- [ ] **Step 1: 写失败的测试**

创建 `test/cli/task_view_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';

/// 给 Agent 看的任务视图。
///
/// 原则：**给事实，不给结论**。哪些镜头挑过素材、每段多长、台词是什么——
/// 都如实摆出来；「该挑哪个」是调用方的判断（见 spec 第一节）。
void main() {
  RenewTask taskWith({List<SemanticUnit>? units}) => RenewTask(
        id: 'abc',
        name: '测试任务',
        sourcePath: '/tmp/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 11),
        updatedAt: DateTime.utc(2026, 8, 11),
        units: units,
        videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: 30000),
          fps: 30,
          fileSizeBytes: 100,
        ),
      );

  test('带上基本信息与分析状态', () {
    final json = taskToJson(taskWith());
    expect(json['id'], 'abc');
    expect(json['name'], '测试任务');
    expect(json['status'], 'ready');
    expect(json['durationMs'], 30000);
    expect(json['fps'], 30);
  });

  test('单元与镜头逐条列出，带时间与台词', () {
    final json = taskToJson(taskWith(units: [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 5000,
        transcript: '第一句',
        tags: const ['促单'],
        shots: const [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 5000),
        ],
      ),
    ]));

    final units = json['units'] as List;
    expect(units, hasLength(1));
    final u = units.single as Map;
    expect(u['index'], 0);
    expect(u['startMs'], 0);
    expect(u['endMs'], 5000);
    expect(u['transcript'], '第一句');
    expect(u['tags'], ['促单']);
    expect((u['shots'] as List), hasLength(2));
    expect((u['shots'] as List).first, {'index': 0, 'startMs': 0, 'endMs': 2000, 'durationMs': 2000, 'tags': <String>[]});
  });

  test('还没分析完时如实说，而不是给一个空数组冒充「没有单元」', () {
    final json = taskToJson(taskWith(units: null));
    expect(json['analyzed'], isFalse);
    expect(json['units'], isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/cli/task_view_test.dart`
Expected: FAIL，`lib/cli/task_view.dart` 不存在

- [ ] **Step 3: 实现视图**

创建 `lib/cli/task_view.dart`：

```dart
import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';

/// 任务的 JSON 视图——**给事实，不给结论**。
///
/// 哪些镜头挑过素材、每段多长、台词是什么，都如实摆出来；「该挑哪个」
/// 是调用方的判断（见 spec「软件提供事实与保护，skill 提供方法论」）。
///
/// `analyzed` 与 `units: null` 是两件事：还没分析完就是 null，不能拿空数组
/// 冒充「分析完了但没有单元」——调用方据此决定是等还是继续。
Map<String, dynamic> taskToJson(RenewTask task) {
  final units = task.units;
  return {
    'id': task.id,
    'name': task.name,
    'status': task.status.name,
    'sourcePath': task.sourcePath,
    'durationMs': task.videoInfo?.duration.inMilliseconds,
    'fps': task.videoInfo?.fps,
    'analyzed': units != null,
    'analysisError': task.analysisError,
    'units': units == null ? null : [for (final u in units) _unitToJson(u)],
    'exports': [
      for (final e in task.exports)
        {
          'at': e.at.toIso8601String(),
          'total': e.total,
          'succeeded': e.succeeded,
          'outputDir': e.outputDir,
        },
    ],
  };
}

Map<String, dynamic> _unitToJson(SemanticUnit unit) => {
      'index': unit.index,
      'startMs': unit.startMs,
      'endMs': unit.endMs,
      'durationMs': unit.endMs - unit.startMs,
      'transcript': unit.transcript,
      'tags': unit.tags,
      'shots': [
        for (var i = 0; i < unit.shots.length; i++)
          {
            'index': i,
            'startMs': unit.shots[i].startMs,
            'endMs': unit.shots[i].endMs,
            'durationMs': unit.shots[i].endMs - unit.shots[i].startMs,
            'tags': unit.shots[i].tags,
          },
      ],
    };
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/cli/task_view_test.dart`
Expected: PASS

- [ ] **Step 5: 接上命令**

创建 `lib/cli/commands/task_command.dart`：

```dart
import 'dart:io';

import '../../core/storage/file_task_repository.dart';
import '../cli_output.dart';
import '../task_view.dart';

/// `ishkafel task <id>` —— 打印任务全貌。
///
/// 找不到时给 exitNotFound 而不是空对象：调用方要能区分「任务不存在」
/// 与「任务存在但还没分析」。
Future<int> runTaskCommand({
  required List<String> rest,
  required Directory dataDir,
  StringSink? out,
  StringSink? err,
}) async {
  if (rest.isEmpty) {
    (err ?? stderr).writeln('用法：ishkafel task <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;
  final task = await FileTaskRepository(dataDir).findById(id);
  if (task == null) {
    (err ?? stderr).writeln('没有这个任务：$id');
    return exitNotFound;
  }
  emitJson(taskToJson(task), out: out);
  return 0;
}
```

在 `bin/ishkafel.dart` 里把 `_usage` 的命令段改成：

```
命令：
  task <id>        任务全貌（单元、镜头、标签、导出历史）
```

并把分发改成：

```dart
  final command = parsed.rest.first;
  final rest = parsed.rest.skip(1).toList();
  final dataDir = resolveDataDir(override: parsed['data-dir'] as String?);

  final code = switch (command) {
    'task' => await runTaskCommand(rest: rest, dataDir: dataDir),
    _ => _unknown(command, parser),
  };
  exit(code);
```

`_unknown` 打印用法并返回 `exitBadUsage`。同时把 `import 'package:ishkafel/cli/data_dir.dart';` 与 `task_command.dart` 加进 import。

- [ ] **Step 6: 真机验证**

Run:
```bash
./scripts/build_cli.sh
build/ishkafel task hl30v3y45q | head -c 400
build/ishkafel task 不存在的; echo "退出码 $?"
```
Expected: 第一条打印真实任务的 JSON；第二条 stderr 提示「没有这个任务」，退出码 3

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat(cli): ishkafel task —— 任务全貌

给事实不给结论：单元、镜头、时间、台词、标签、导出历史如实摆出来，
「该挑哪个」是调用方的判断。

analyzed 与 units:null 分开表达——还没分析完就是 null，不能拿空数组
冒充「分析完了但没有单元」，调用方据此决定是等还是继续。

找不到任务给退出码 3，与「任务存在但还没分析」区分开。"
```

---

### Task 4: 任务锁

**Files:**
- Create: `lib/core/storage/task_lock.dart`
- Test: `test/core/storage/task_lock_test.dart`

**Interfaces:**
- Consumes: 无（纯 Dart + `dart:io`）
- Produces:
  - `class TaskLock { final String holder; final DateTime acquiredAt; final DateTime heartbeatAt; bool isStale(DateTime now); }`
  - `class TaskLockFile { TaskLockFile({required Directory dataDir, required String taskId, Duration staleAfter}); TaskLock? read(); bool acquire(String holder, {DateTime? now}); bool heartbeat(String holder, {DateTime? now}); void release(String holder); void forceTakeover(String newHolder, {DateTime? now}); }`
  - `const Duration defaultStaleAfter = Duration(seconds: 60);`

- [ ] **Step 1: 写失败的测试**

创建 `test/core/storage/task_lock_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/task_lock.dart';

/// Agent 在跑、人又打开了 GUI，两边都写同一份任务 JSON——后写的把先写的
/// 覆盖掉，而且悄无声息。这是真实的数据丢失，且**只有软件看得见两个写入方**，
/// 所以必须软件来管（见 spec 第一节的判据）。
///
/// 最要紧的一条：**锁必须能自愈**。否则持有者一崩，这个任务就再也打不开了。
void main() {
  late Directory dir;
  TaskLockFile lockFor(String holder) =>
      TaskLockFile(dataDir: dir, taskId: 't1');

  setUp(() => dir = Directory.systemTemp.createTempSync('ishkafel_lock_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('没人持有时能拿到', () {
    expect(lockFor('agent').acquire('agent'), isTrue);
    expect(lockFor('agent').read()?.holder, 'agent');
  });

  test('别人持着时拿不到', () {
    lockFor('agent').acquire('agent');
    expect(lockFor('gui').acquire('gui'), isFalse);
  });

  test('同一个持有者重复获取算成功——重入不该失败', () {
    lockFor('agent').acquire('agent');
    expect(lockFor('agent').acquire('agent'), isTrue);
  });

  test('心跳停了超过阈值就算失效，别人可以拿——锁必须能自愈', () {
    final now = DateTime.utc(2026, 8, 11, 12, 0, 0);
    lockFor('agent').acquire('agent', now: now);

    final lock = lockFor('gui');
    expect(lock.read()!.isStale(now.add(const Duration(seconds: 30))), isFalse);
    expect(lock.read()!.isStale(now.add(const Duration(seconds: 61))), isTrue);
  });

  test('心跳能续命', () {
    final now = DateTime.utc(2026, 8, 11, 12, 0, 0);
    lockFor('agent').acquire('agent', now: now);
    lockFor('agent').heartbeat('agent', now: now.add(const Duration(seconds: 50)));

    final lock = lockFor('gui').read()!;
    expect(lock.isStale(now.add(const Duration(seconds: 80))), isFalse,
        reason: '心跳之后重新计时');
  });

  test('不是持有者，心跳无效', () {
    final now = DateTime.utc(2026, 8, 11, 12, 0, 0);
    lockFor('agent').acquire('agent', now: now);
    expect(lockFor('gui').heartbeat('gui', now: now), isFalse);
  });

  test('释放之后别人能拿', () {
    lockFor('agent').acquire('agent');
    lockFor('agent').release('agent');
    expect(lockFor('gui').acquire('gui'), isTrue);
  });

  test('不是持有者，释放无效——不能替别人放锁', () {
    lockFor('agent').acquire('agent');
    lockFor('gui').release('gui');
    expect(lockFor('x').read()?.holder, 'agent');
  });

  test('强制接管：人要抢就能抢，抢完持有者换人', () {
    lockFor('agent').acquire('agent');
    lockFor('gui').forceTakeover('gui');
    expect(lockFor('x').read()?.holder, 'gui');
  });

  test('锁文件坏了当作没锁——一个读不懂的锁不该把任务永久封死', () {
    Directory('${dir.path}/locks').createSync(recursive: true);
    File('${dir.path}/locks/t1.json').writeAsStringSync('{坏掉的');
    expect(lockFor('gui').read(), isNull);
    expect(lockFor('gui').acquire('gui'), isTrue);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/core/storage/task_lock_test.dart`
Expected: FAIL，`task_lock.dart` 不存在

- [ ] **Step 3: 实现**

创建 `lib/core/storage/task_lock.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';

/// 心跳停多久算失效。
///
/// **锁必须能自愈**：持有者可能崩溃、可能被 kill、可能断电。没有这条，
/// 任务会被一把永远不会释放的锁封死，而用户完全无从下手。
const Duration defaultStaleAfter = Duration(seconds: 60);

/// 一把任务锁的内容
class TaskLock {
  /// 谁持有（`agent:<pid>` / `gui:<pid>`）——出问题时要能说出是谁占着
  final String holder;
  final DateTime acquiredAt;
  final DateTime heartbeatAt;
  final Duration staleAfter;

  const TaskLock({
    required this.holder,
    required this.acquiredAt,
    required this.heartbeatAt,
    this.staleAfter = defaultStaleAfter,
  });

  bool isStale(DateTime now) => now.difference(heartbeatAt) > staleAfter;

  Map<String, dynamic> toJson() => {
        'holder': holder,
        'acquiredAt': acquiredAt.toIso8601String(),
        'heartbeatAt': heartbeatAt.toIso8601String(),
      };

  static TaskLock? tryFromJson(Object? raw, Duration staleAfter) {
    if (raw is! Map) return null;
    final holder = raw['holder'];
    final acquired = DateTime.tryParse('${raw['acquiredAt']}');
    final heartbeat = DateTime.tryParse('${raw['heartbeatAt']}');
    if (holder is! String || acquired == null || heartbeat == null) return null;
    return TaskLock(
      holder: holder,
      acquiredAt: acquired,
      heartbeatAt: heartbeat,
      staleAfter: staleAfter,
    );
  }
}

/// 落在盘上的任务锁：`<dataDir>/locks/<taskId>.json`。
///
/// 用文件而不是内存：Agent 与 GUI 是两个进程，只有磁盘是它们的公共地面。
class TaskLockFile {
  final Directory dataDir;
  final String taskId;
  final Duration staleAfter;

  TaskLockFile({
    required this.dataDir,
    required this.taskId,
    this.staleAfter = defaultStaleAfter,
  });

  File get _file =>
      File(p.join(dataDir.path, 'locks', '$taskId.json'));

  /// 当前的锁；没有、已失效、或文件坏了都返回 null。
  ///
  /// **读不懂就当没锁**：一个解析不了的锁文件不该把任务永久封死。
  TaskLock? read() {
    final file = _file;
    if (!file.existsSync()) return null;
    try {
      return TaskLock.tryFromJson(jsonDecode(file.readAsStringSync()), staleAfter);
    } catch (e) {
      AppLog.warn('任务锁读不懂，当作没有锁（$taskId）：$e');
      return null;
    }
  }

  /// 拿锁。已被别人持有且未失效时返回 false。
  bool acquire(String holder, {DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    final current = read();
    if (current != null &&
        current.holder != holder &&
        !current.isStale(at)) {
      return false;
    }
    _write(TaskLock(holder: holder, acquiredAt: at, heartbeatAt: at));
    return true;
  }

  /// 续命。不是持有者时返回 false——不能替别人续
  bool heartbeat(String holder, {DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    final current = read();
    if (current == null || current.holder != holder) return false;
    _write(TaskLock(
        holder: holder, acquiredAt: current.acquiredAt, heartbeatAt: at));
    return true;
  }

  /// 放锁。**不是持有者就什么都不做**——不能替别人放
  void release(String holder) {
    final current = read();
    if (current == null || current.holder != holder) return;
    try {
      _file.deleteSync();
    } catch (e) {
      AppLog.warn('释放任务锁失败（$taskId）：$e');
    }
  }

  /// 强制接管：人要抢就能抢。抢完之后原持有者的写入会被拒绝
  void forceTakeover(String newHolder, {DateTime? now}) {
    final at = now ?? DateTime.now().toUtc();
    _write(TaskLock(holder: newHolder, acquiredAt: at, heartbeatAt: at));
  }

  void _write(TaskLock lock) {
    final file = _file;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(lock.toJson()));
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/core/storage/task_lock_test.dart`
Expected: 11 条全 PASS

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "feat: 任务锁

Agent 在跑、人又打开了 GUI，两边都写同一份任务 JSON——后写的把先写的
覆盖掉，而且悄无声息。这是真实的数据丢失，且只有软件看得见两个写入方，
所以必须软件来管。

用文件而不是内存：Agent 与 GUI 是两个进程，只有磁盘是公共地面。

两条守死的规矩：
- **锁必须能自愈**。心跳停 60 秒即失效，否则持有者一崩，任务就再也打不开
- **读不懂的锁当作没锁**。一个解析不了的锁文件不该把任务永久封死

不能替别人续命，也不能替别人放锁；但人可以强制接管——那是产品决定的
出路，抢完之后原持有者的写入会被拒绝。"
```

---

### Task 5: GUI 只读态与强制接管

**Files:**
- Create: `lib/features/workbench/task_lock_banner.dart`
- Modify: `lib/features/workbench/workbench_page.dart`
- Test: `test/features/workbench/task_lock_ui_test.dart`

**Interfaces:**
- Consumes: `TaskLockFile`、`TaskLock`（Task 4）
- Produces: `TaskLockBanner({required String holder, required VoidCallback onTakeover})` — 顶部横幅

- [ ] **Step 1: 写失败的测试**

创建 `test/features/workbench/task_lock_ui_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/task_lock_banner.dart';

/// 任务被 Agent 锁住时，界面必须**说清楚并给出路**。
///
/// 只把编辑禁掉而不说原因，用户只会以为软件坏了——这是本项目反复踩过的坑
/// （见 CLAUDE.md「状态必须可见且可操作」）。
void main() {
  testWidgets('说清楚是谁占着，以及现在能做什么', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskLockBanner(holder: 'agent:1234', onTakeover: () {}),
      ),
    ));

    expect(find.textContaining('正在操作这个任务'), findsOneWidget);
    expect(find.textContaining('只读'), findsOneWidget);
    expect(find.byKey(const Key('lock-takeover')), findsOneWidget);
  });

  testWidgets('强制接管要先确认——那会让对方的写入被拒绝', (tester) async {
    var taken = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TaskLockBanner(holder: 'agent:1234', onTakeover: () => taken = true),
      ),
    ));

    await tester.tap(find.byKey(const Key('lock-takeover')));
    await tester.pumpAndSettle();
    expect(find.textContaining('强制接管'), findsWidgets);
    expect(taken, isFalse, reason: '还没确认就不该真的接管');

    await tester.tap(find.byKey(const Key('lock-takeover-confirm')));
    await tester.pumpAndSettle();
    expect(taken, isTrue);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/features/workbench/task_lock_ui_test.dart`
Expected: FAIL，`task_lock_banner.dart` 不存在

- [ ] **Step 3: 实现横幅**

创建 `lib/features/workbench/task_lock_banner.dart`：

```dart
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 「这个任务正被别人操作」的横幅。
///
/// 只把编辑禁掉而不说原因，用户只会以为软件坏了——所以这里要说清三件事：
/// 谁占着、现在能做什么、想接管怎么办。
class TaskLockBanner extends StatelessWidget {
  final String holder;
  final VoidCallback onTakeover;

  const TaskLockBanner({
    super.key,
    required this.holder,
    required this.onTakeover,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        color: AppColors.orange.withValues(alpha: 0.14),
        child: Row(
          children: [
            const Icon(Icons.lock_clock_rounded,
                size: 16, color: AppColors.orange),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '$holder 正在操作这个任务，当前为只读。'
                '它结束后会自动解锁；也可以强制接管，但那会让它后续的写入被拒绝。',
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    height: 1.5,
                    color: AppColors.textPrimary),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            TextButton(
              key: const Key('lock-takeover'),
              onPressed: () => _confirm(context),
              child: const Text('强制接管'),
            ),
          ],
        ),
      );

  Future<void> _confirm(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('强制接管这个任务？'),
        content: Text('$holder 还在操作它。接管之后它后续的写入会被拒绝，'
            '已经写进去的改动不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消')),
          TextButton(
            key: const Key('lock-takeover-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('接管', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (yes == true) onTakeover();
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/features/workbench/task_lock_ui_test.dart`
Expected: PASS

- [ ] **Step 5: 接进工作台**

在 `lib/features/workbench/workbench_page.dart`：

1. 加字段与轮询——**每 5 秒查一次锁**（比 60 秒的失效阈值密得多，锁一释放很快就能恢复可编辑）：

```dart
  TaskLock? _lock;
  Timer? _lockTimer;

  /// 谁在写这份任务。GUI 自报家门，出问题时横幅上能说出是谁占着
  String get _lockHolder => 'gui:$pid';

  void _watchLock() {
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;
    final file = TaskLockFile(dataDir: dataDir, taskId: widget.task.id);
    void poll() {
      final current = file.read();
      final held = current != null && current.holder != _lockHolder;
      if (held == (_lock != null) && current?.holder == _lock?.holder) return;
      setState(() => _lock = held ? current : null);
    }
    poll();
    _lockTimer = Timer.periodic(const Duration(seconds: 5), (_) => poll());
  }
```

在 `initState` 末尾调 `_watchLock()`，在 `dispose` 里 `_lockTimer?.cancel()`。

2. 在页面主体最上方插入横幅，并把只读传下去：

```dart
        if (_lock case final lock?)
          TaskLockBanner(
            holder: lock.holder,
            onTakeover: () {
              final dataDir = ref.read(dataDirProvider);
              if (dataDir == null) return;
              TaskLockFile(dataDir: dataDir, taskId: widget.task.id)
                  .forceTakeover(_lockHolder);
              setState(() => _lock = null);
            },
          ),
```

3. 把 `WorkbenchBody` 的 `readOnly` 参数改成 `readOnly: !_isEditable || _lock != null`（`readOnly` 已存在，回看模式在用）。

- [ ] **Step 6: 真机验证**

Run:
```bash
# 手动造一把别人的锁
mkdir -p ~/Library/Application\ Support/com.jichuang.ishkafel/ishkafel_data/locks
cat > ~/Library/Application\ Support/com.jichuang.ishkafel/ishkafel_data/locks/hl30v3y45q.json <<'JSON'
{"holder":"agent:9999","acquiredAt":"2099-01-01T00:00:00.000Z","heartbeatAt":"2099-01-01T00:00:00.000Z"}
JSON
flutter build macos --debug && open build/macos/Build/Products/Debug/ishkafel.app
```
Expected: 打开那个任务时顶部出现橙色横幅、编辑控件为只读；点「强制接管」并确认后横幅消失、恢复可编辑。验证完删掉那个锁文件。

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat: 任务被别人占着时，工作台切只读并说明出路

Agent 在跑而人打开了 GUI，两边都写同一份任务 JSON 会互相覆盖。锁本身在
上一个任务里做好了，这里是它在界面上的样子。

只把编辑禁掉而不说原因，用户只会以为软件坏了——所以横幅要说清三件事：
谁占着、现在是只读、想接管怎么办。强制接管是破坏性的（对方后续写入会被
拒绝），所以要确认。

每 5 秒查一次锁，比 60 秒的失效阈值密得多——对方一结束，很快就能恢复编辑。"
```

---

### Task 6: `ishkafel candidates` —— 候选素材与上下文

**Files:**
- Create: `lib/cli/commands/candidates_command.dart`
- Create: `lib/cli/candidate_context.dart`
- Move: `lib/features/picking/tag_id_resolver.dart` → `lib/core/miaoa/tag_id_resolver.dart`
- Modify: 引用它的 `lib/features/workbench/candidate_tab.dart`、`lib/features/picking/picking_scope.dart` 等（改 import 路径）
- Modify: `bin/ishkafel.dart`
- Test: `test/cli/candidate_context_test.dart`

**Interfaces:**
- Consumes: `taskToJson` 依赖的模型；`RenewTask`、`SemanticUnit`、`UnitReplacement`
- Produces:
  - `Map<String, dynamic> shotContext({required RenewTask task, required int unitIndex, required int shotIndex})`

- [ ] **Step 1: 写失败的测试**

创建 `test/cli/candidate_context_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/candidate_context.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 挑素材时给 Agent 的**上下文**。
///
/// 只给「这个镜头 2.8 秒、标签是厨房清洁」，Agent 很容易挑出**每一个都合规、
/// 连起来很怪**的组合——人挑的时候是有整体感的。软件的职责是把上下文这个
/// *事实*开放出来；「要和前后顺不顺」这条方法论写在 skill 里（见 spec 第一节）。
void main() {
  final task = RenewTask(
    id: 't',
    name: 'n',
    sourcePath: '/tmp/a.mp4',
    status: RenewTaskStatus.ready,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    units: [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 6000,
        transcript: '这个东西能把衣服洗干净',
        tags: const ['主卖点'],
        shots: const [
          Shot(startMs: 0, endMs: 2000, description: '手拿瓶子'),
          Shot(startMs: 2000, endMs: 4000, description: '倒进洗衣机'),
          Shot(startMs: 4000, endMs: 6000, description: '衣服特写'),
        ],
      ),
    ],
    replacements: [
      UnitReplacement.perShot(const {
        0: [101]
      }, previewIds: const {0: 101}),
    ],
  );

  test('带上本单元的台词——那是这一段在讲什么', () {
    final ctx = shotContext(task: task, unitIndex: 0, shotIndex: 1);
    expect(ctx['unitTranscript'], '这个东西能把衣服洗干净');
    expect(ctx['unitTags'], ['主卖点']);
  });

  test('带上相邻镜头的画面描述——避免连起来很怪', () {
    final ctx = shotContext(task: task, unitIndex: 0, shotIndex: 1);
    expect((ctx['previous'] as Map)['description'], '手拿瓶子');
    expect((ctx['next'] as Map)['description'], '衣服特写');
  });

  test('相邻镜头已经挑过素材的话，说出来——组方案时要避开雷同', () {
    final ctx = shotContext(task: task, unitIndex: 0, shotIndex: 1);
    expect((ctx['previous'] as Map)['pickedMaterialIds'], [101]);
  });

  test('首尾镜头没有前/后，给 null 而不是编一个', () {
    final first = shotContext(task: task, unitIndex: 0, shotIndex: 0);
    expect(first['previous'], isNull);
    final last = shotContext(task: task, unitIndex: 0, shotIndex: 2);
    expect(last['next'], isNull);
  });

  test('这个镜头本身的坑位长度要给——变速倍率靠它算', () {
    final ctx = shotContext(task: task, unitIndex: 0, shotIndex: 1);
    expect(ctx['slotMs'], 2000);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/cli/candidate_context_test.dart`
Expected: FAIL，`candidate_context.dart` 不存在

- [ ] **Step 3: 实现**

创建 `lib/cli/candidate_context.dart`：

```dart
import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';
import '../core/replacement/replacement_plan.dart';

/// 挑这个镜头的素材时，调用方需要知道的**周边事实**。
///
/// 只给「这个镜头 2.8 秒、标签是厨房清洁」，很容易挑出每一个都合规、连起来
/// 很怪的组合——人挑的时候是有整体感的：知道这里是开箱、那里是演示效果。
///
/// 软件只负责把这些事实摆出来。「要和前后顺不顺」「同批微调版要挑差异大的」
/// 是方法论，写在给 Agent 的 skill 里，不硬编码进这里。
Map<String, dynamic> shotContext({
  required RenewTask task,
  required int unitIndex,
  required int shotIndex,
}) {
  final units = task.units ?? const <SemanticUnit>[];
  final unit = units[unitIndex];
  final shots = unit.shots;
  final shot = shots[shotIndex];

  return {
    'unitIndex': unitIndex,
    'shotIndex': shotIndex,
    'slotMs': shot.endMs - shot.startMs,
    'description': shot.description,
    'tags': shot.tags,
    'unitTranscript': unit.transcript,
    'unitTags': unit.tags,
    'previous': shotIndex == 0
        ? null
        : _neighbour(task, unitIndex, shotIndex - 1),
    'next': shotIndex >= shots.length - 1
        ? null
        : _neighbour(task, unitIndex, shotIndex + 1),
  };
}

Map<String, dynamic> _neighbour(RenewTask task, int unitIndex, int shotIndex) {
  final shot = task.units![unitIndex].shots[shotIndex];
  return {
    'shotIndex': shotIndex,
    'description': shot.description,
    'tags': shot.tags,
    'durationMs': shot.endMs - shot.startMs,
    // 相邻镜头已经挑了什么：组方案时要避开和它雷同的素材
    'pickedMaterialIds': _pickedFor(task, unitIndex, shotIndex),
  };
}

List<int> _pickedFor(RenewTask task, int unitIndex, int shotIndex) {
  final replacements = task.replacements;
  if (replacements == null || unitIndex >= replacements.length) return const [];
  return replacements[unitIndex].shotCandidateIds[shotIndex] ?? const [];
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/cli/candidate_context_test.dart`
Expected: PASS

- [ ] **Step 5: 把 TagIdResolver 挪进 core**

它只依赖 `core/`（ffmpeg、log、miaoa），放在 `features/picking/` 下纯属历史
位置——而 CLI 不该依赖 UI 层。

```bash
git mv lib/features/picking/tag_id_resolver.dart lib/core/miaoa/tag_id_resolver.dart
# 修正它自己的相对 import：'../../core/xxx' → '../xxx'
# 再把引用方的 import 路径全改过来
grep -rln "picking/tag_id_resolver.dart" lib/ test/
```

Run: `flutter analyze && flutter test test/features/workbench/ test/features/picking/`
Expected: analyze 无 issue，相关测试全绿（这是纯搬家，行为不该有任何变化）

- [ ] **Step 6: 接上命令**

创建 `lib/cli/commands/candidates_command.dart`：

```dart
import 'dart:io';

import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_locator.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/miaoa/tag_id_resolver.dart';
import '../../core/storage/file_task_repository.dart';
import '../candidate_context.dart';
import '../cli_output.dart';

/// `ishkafel candidates <task> --unit i [--shot j]`
///
/// 返回候选素材 + **上下文**。候选带 miaoa 的图片 URL（按 spec 的决定，
/// 不落地、由调用方自己看图）。
Future<int> runCandidatesCommand({
  required List<String> rest,
  required Directory dataDir,
  required int? unitIndex,
  required int? shotIndex,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty || unitIndex == null) {
    sink.writeln('用法：ishkafel candidates <任务 id> --unit <单元下标> [--shot <镜头下标>]');
    return exitBadUsage;
  }
  final task = await FileTaskRepository(dataDir).findById(rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final units = task.units;
  if (units == null) {
    sink.writeln('这个任务还没分析完，没有单元可挑。先跑 ishkafel analyze');
    return exitNotFound;
  }
  if (unitIndex < 0 || unitIndex >= units.length) {
    sink.writeln('没有第 $unitIndex 个单元（共 ${units.length} 个）');
    return exitNotFound;
  }
  final shots = units[unitIndex].shots;
  if (shotIndex != null && (shotIndex < 0 || shotIndex >= shots.length)) {
    sink.writeln('U${unitIndex + 1} 没有第 $shotIndex 个镜头（共 ${shots.length} 个）');
    return exitNotFound;
  }

  // 打标产出的是标签**名**，而 miaoa 的检索只收标签 **id**，中间必须有一次
  // 映射，映射表来自任务选定的标签组（见 TagIdResolver 的类文档）
  final tagService = MiaoaTagService(binary: resolveMiaoaBinary());
  final resolver = TagIdResolver(tagService);
  await resolver.loadAll({
    for (final g in task.unitTagGroups) g.id,
    for (final g in task.shotTagGroups) g.id,
  });
  if (resolver.loadFailure case final failure?) {
    sink.writeln(failure);
    return 1;
  }

  final tagNames =
      shotIndex == null ? units[unitIndex].tags : shots[shotIndex].tags;
  final tagIds = resolver.idsOf(tagNames);
  if (tagIds.isEmpty) {
    sink.writeln(tagNames.isEmpty
        ? '这一层还没有标签，无法按标签检索。先确认任务选了标签组、且已完成打标'
        : '这些标签在素材库里找不到对应项（可能已被改名或删除）：${tagNames.join('、')}');
    return exitNotFound;
  }

  final page = await MiaoaContentService(binary: resolveMiaoaBinary())
      .searchByTags(
    tagIds: tagIds,
    mode: 'or',
    projectIds: [?task.project?.id],
    pageSize: 50,
  );

  emitJson({
    'context': shotIndex == null
        ? {
            'unitIndex': unitIndex,
            'slotMs': units[unitIndex].endMs - units[unitIndex].startMs,
            'unitTranscript': units[unitIndex].transcript,
            'unitTags': units[unitIndex].tags,
          }
        : shotContext(task: task, unitIndex: unitIndex, shotIndex: shotIndex),
    'total': page.total,
    'candidates': [
      for (final c in page.items)
        {
          'id': c.id,
          'name': c.name,
          'description': c.sceneDescription,
          'voiceover': c.voiceover,
          'tags': c.tags,
          // 按 spec 的决定：给 URL、不落地，看不看图是调用方的事
          'thumbnailUrl': c.thumbnailUrl,
          'previewUrl': c.previewUrl,
        },
    ],
  }, out: out);
  return 0;
}
```

> **候选不带时长**：`CandidateMaterial` 里没有 `durationMs`——miaoa 的检索
> 结果不含时长，现在 GUI 上那个「+1.5s」是另外逐条探测出来的（每条一次网络
> + ffprobe）。在候选列表里同步做会让这条命令慢到不可用。变速可行性的判断
> 放到第二期的方案提交时做，那时只需要探测被真正选中的那几条。



在 `bin/ishkafel.dart` 的 `ArgParser` 加：

```dart
    ..addOption('unit', help: '单元下标（从 0 开始）')
    ..addOption('shot', help: '镜头下标（从 0 开始）')
```

分发里加一条：

```dart
    'candidates' => await runCandidatesCommand(
        rest: rest,
        dataDir: dataDir,
        unitIndex: int.tryParse(parsed['unit'] as String? ?? ''),
        shotIndex: int.tryParse(parsed['shot'] as String? ?? ''),
      ),
```

用法段加：

```
  candidates <id> --unit <i> [--shot <j>]
                   候选素材与上下文（本单元台词、相邻镜头、已选素材）
```

- [ ] **Step 7: 真机验证**

Run: `./scripts/build_cli.sh && build/ishkafel candidates hl30v3y45q --unit 1 --shot 5 | head -c 600`
Expected: 打印 context（含 `unitTranscript`、`previous`、`next`）与 candidates 数组（含 `previewUrl`）

- [ ] **Step 8: 提交**

```bash
git add -A
git commit -m "feat(cli): ishkafel candidates —— 候选素材与上下文

只给「这个镜头 2.8 秒、标签是厨房清洁」，很容易挑出每一个都合规、连起来
很怪的组合——人挑的时候是有整体感的。所以候选清单要带上周边事实：
本单元台词、相邻镜头的画面描述与它们已选的素材、这个坑位多长。

软件只摆事实。「要和前后顺不顺」「同批微调版要挑差异大的」是方法论，
写在给 Agent 的 skill 里，不硬编码进这里。

候选带 miaoa 的图片 URL、不落地——按 spec 的决定，看不看图、怎么看
是调用方的事。

顺带把 TagIdResolver 从 features/picking 挪进 core/miaoa：它只依赖 core，
放在 UI 层下面纯属历史位置，而 CLI 不该依赖 features。"
```

---

### Task 7: `ishkafel open` —— 转人工审核

**Files:**
- Create: `lib/cli/commands/open_command.dart`
- Modify: `bin/ishkafel.dart`
- Modify: `lib/main.dart`
- Test: `test/cli/open_command_test.dart`

**Interfaces:**
- Consumes: `resolveDataDir`、`exitNotFound`
- Produces: `Future<int> runOpenCommand({required List<String> rest, required Directory dataDir, required Future<ProcessResult> Function(String, List<String>) run, StringSink? err})`

- [ ] **Step 1: 写失败的测试**

创建 `test/cli/open_command_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/open_command.dart';

/// `ishkafel open <task>` —— 把 GUI 弹出来并落到这个任务。
///
/// 这是「Agent 做到某一步、让我审核」的落地方式。因为 GUI 和 CLI 读同一份
/// 任务数据，不需要任何进程间通信——只要把 app 拉起来、告诉它开哪个任务。
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ishkafel_open_');
    Directory('${dir.path}/tasks').createSync(recursive: true);
    File('${dir.path}/tasks/t1.json').writeAsStringSync('{"id":"t1"}');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('用 open -a 把 app 拉起来，并把任务 id 作为参数传过去', () async {
    final calls = <List<String>>[];
    final code = await runOpenCommand(
      rest: ['t1'],
      dataDir: dir,
      run: (bin, args) async {
        calls.add([bin, ...args]);
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(code, 0);
    expect(calls.single, containsAllInOrder(['open', '-a']));
    expect(calls.single, containsAllInOrder(['--args', '--task=t1']));
  });

  test('任务不存在时不去拉 app——省得弹出一个空窗口让人困惑', () async {
    var launched = false;
    final code = await runOpenCommand(
      rest: ['不存在'],
      dataDir: dir,
      run: (bin, args) async {
        launched = true;
        return ProcessResult(0, 0, '', '');
      },
    );
    expect(code, isNot(0));
    expect(launched, isFalse);
  });

  test('拉起失败时如实报错，不假装成功', () async {
    final code = await runOpenCommand(
      rest: ['t1'],
      dataDir: dir,
      run: (bin, args) async => ProcessResult(0, 1, '', 'app not found'),
    );
    expect(code, isNot(0));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/cli/open_command_test.dart`
Expected: FAIL，`open_command.dart` 不存在

- [ ] **Step 3: 实现命令**

创建 `lib/cli/commands/open_command.dart`：

```dart
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli_output.dart';

/// app 的安装位置。装在别处时用 ISHKAFEL_APP 指定
const String defaultAppPath = '/Applications/ishkafel.app';

/// `ishkafel open <task>` —— 把 GUI 弹出来并落到这个任务的工作台。
///
/// 这是「Agent 做到某一步、让我审核」的落地方式。GUI 和 CLI 读同一份任务
/// 数据，所以不需要任何进程间通信——把 app 拉起来、告诉它开哪个任务就够了。
Future<int> runOpenCommand({
  required List<String> rest,
  required Directory dataDir,
  Future<ProcessResult> Function(String, List<String>)? run,
  Map<String, String>? env,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel open <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;
  // 先确认任务在不在：拉起一个空窗口只会让人困惑
  if (!File(p.join(dataDir.path, 'tasks', '$id.json')).existsSync()) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  final appPath =
      (env ?? Platform.environment)['ISHKAFEL_APP'] ?? defaultAppPath;
  final exec = run ?? Process.run;
  final result = await exec('open', ['-a', appPath, '--args', '--task=$id']);
  if (result.exitCode != 0) {
    sink.writeln('打不开 app（$appPath）：${result.stderr}'.trim());
    return 1;
  }
  return 0;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/cli/open_command_test.dart`
Expected: PASS

- [ ] **Step 5: GUI 认这个参数**

在 `lib/main.dart` 里，`runApp` 之前解析启动参数，并把它交给根 widget：

```dart
/// 启动时要直接打开哪个任务（`--task=<id>`）。
///
/// CLI 的 `ishkafel open <task>` 靠它落到工作台——这是「Agent 做到某一步、
/// 让我审核」的最后一环。参数认不出来时返回 null，照常进列表页。
String? initialTaskIdFrom(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--task=')) {
      final id = arg.substring('--task='.length).trim();
      if (id.isNotEmpty) return id;
    }
  }
  return null;
}
```

`main()` 改成接收 `List<String> args`（Flutter 的 macOS 入口会把命令行参数传进来），把 `initialTaskIdFrom(args)` 存进一个 provider（如 `initialTaskIdProvider`），列表页在首帧后若该值非空且能找到任务，就直接 push 工作台。

补一条测试进 `test/cli/open_command_test.dart`：

```dart
  test('认得出 --task= 参数，认不出时返回 null', () {
    expect(initialTaskIdFrom(['--task=abc']), 'abc');
    expect(initialTaskIdFrom(['--other', '--task=x1']), 'x1');
    expect(initialTaskIdFrom(['--task=']), isNull);
    expect(initialTaskIdFrom([]), isNull);
  });
```

（`initialTaskIdFrom` 从 `package:ishkafel/main.dart` import。）

- [ ] **Step 6: 接进 bin 并真机验证**

`bin/ishkafel.dart` 分发加 `'open' => await runOpenCommand(rest: rest, dataDir: dataDir),`，用法段加 `open <id>  把 app 弹出来并落到这个任务`。

Run:
```bash
./scripts/build_cli.sh
flutter build macos --debug
ISHKAFEL_APP="$PWD/build/macos/Build/Products/Debug/ishkafel.app" build/ishkafel open hl30v3y45q
```
Expected: app 启动并**直接落在那个任务的工作台**，不是列表页

- [ ] **Step 7: 提交**

```bash
git add -A
git commit -m "feat(cli): ishkafel open —— 把 GUI 弹出来转人工审核

「Agent 做到某一步、让我审核」的落地方式。GUI 和 CLI 读同一份任务数据，
所以不需要任何进程间通信——把 app 拉起来、告诉它开哪个任务就够了。

任务不存在时不去拉 app：弹出一个空窗口只会让人困惑。拉起失败如实报错，
不假装成功。"
```

---

## 完成后的验收

这一期做完，下面这串应该能在真机上一路跑通：

```bash
build/ishkafel task hl30v3y45q --json | jq '.units | length'
build/ishkafel candidates hl30v3y45q --unit 1 --shot 5 --json | jq '.context'
build/ishkafel open hl30v3y45q          # app 弹出来落到工作台
```

并且：Agent 持锁期间打开 GUI 是只读的，横幅说明谁占着；强制接管后恢复可编辑；
锁的持有者崩掉 60 秒后自动失效。

## 不在这一期

- **留痕**（spec 第七节）：记「每一步是谁做的」。这一期全是只读命令，还没有
  写入可记；等第二期有了 `apply` 才有意义
- `analyze` 的分步化与外部注入（`--external`）
- `apply segment|tags|shots|plans`
- `export`
- 给 Agent 的 skill 文档

这些进第二期，见 spec 第三、四节。

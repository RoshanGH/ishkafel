import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/agent_request.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/review/review_hover_player.dart';
import 'package:ishkafel/features/review/review_page.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';
import 'package:path/path.dart' as p;

/// **「命令失败的理由只有三类」——人开着某一页不是其中任何一类。**
///
/// 这一页的 `_items` 一度是 `late final`，从进门那一刻的 `widget.task` 取
/// 一次、此后永不重读盘。于是这条很常见的序列会伪造出第四类失败：
///
/// 1. 人开着审片台
/// 2. Agent 跑 `apply plans` → 审片台回 `unsupported` → CLI 自己写盘，
///    新候选落地
/// 3. Agent 跑 `review drop <新候选>` → CLI 先拿**盘上**数据校验，通过 →
///    委派 → 审片台拿**旧快照**判「这一页上没有这些候选」→ `ok:false`
///    → CLI 返回 `exitBadUsage`
///
/// 参数是对的、盘上数据也是对的，唯一的原因是人开着某一页而那一页的数据
/// 旧了。而且那句话本身是**假的**：候选确实存在。
void main() {
  late Directory dataDir;
  late _Repo repo;

  RenewTask taskWith(List<int> candidates) => RenewTask(
        id: 'rv1',
        name: '滴露',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 18),
        updatedAt: DateTime.utc(2026, 9, 18),
        units: const [
          SemanticUnit(
              uid: 'u0', index: 0, startMs: 0, endMs: 5000, transcript: '第一句'),
        ],
        replacementsByUid: {'u0': UnitReplacement.whole(candidates)},
        pickedMaterials: [
          for (final id in candidates)
            PickedMaterial(
                id: id, name: '素材$id', voiceover: '', sceneDescription: ''),
        ],
      );

  /// 盘上那一份。**指纹（大小 + 修改时间）看的就是它**，所以别人写过盘
  /// 这件事必须真的落到文件上——这正是界面判「我手上的是不是旧的」的依据
  void writeToDisk(RenewTask task) {
    final f = File(p.join(dataDir.path, 'tasks', '${task.id}.json'))
      ..parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(task.toJson()));
    // 同一毫秒内连写两次时 mtime 可能一样：把时间明确往后推一秒，
    // 测的是「指纹变了要重读」，不是文件系统的时间分辨率
    f.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 1)));
    repo.tasks[task.id] = task;
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('review_stale_');
    repo = _Repo();
  });
  tearDown(() => dataDir.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, RenewTask task) async {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    writeToDisk(task);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dataDirProvider.overrideWithValue(dataDir),
        taskRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: ReviewPage(
          task: task,
          hoverPlayer: _FakeHoverPlayer(),
          resolveMedia: (_) async => '/tmp/fake.mp4',
          extractOriginalThumb: (_, _, _) async => null,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  String drop(int material) => jsonEncode({
        'decisions': [
          {'unit': 0, 'shot': null, 'material': material, 'keep': false}
        ]
      });

  testWidgets('这期间 CLI 往盘上加了候选：代办照做，不许说「这一页上没有」',
      (tester) async {
    await pump(tester, taskWith([101]));
    expect(find.textContaining('共 1 条'), findsOneWidget);

    // Agent 那一步：apply plans 被这一页回了 unsupported，CLI 自己写了盘
    writeToDisk(taskWith([101, 102]));

    final id = writeAgentRequest(
      dataDir: dataDir,
      taskId: 'rv1',
      kind: 'review.drop',
      payload: jsonDecode(drop(102)) as Map<String, dynamic>,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final result = await waitForAgentRequest(
        dataDir: dataDir,
        taskId: 'rv1',
        id: id,
        timeout: const Duration(milliseconds: 100));
    expect(result!.ok, isTrue,
        reason: '候选真在盘上，这一页只是自己的快照旧了——'
            '拿这个当失败理由就是第四类失败，而且那句话是假的');
    // 界面也要跟上：新候选摆出来了，而且被标成已剔除
    expect(find.textContaining('共 2 条'), findsOneWidget,
        reason: '答应了就要看得见——不然人按确认时剔的是一张他没见过的卡');
    expect(find.text('已剔除'), findsOneWidget);
    // 人还没按确认，盘上的方案一条都不许少
    expect(repo.tasks['rv1']!.replacementsByUid['u0']!.wholeCandidateIds,
        [101, 102]);
  });

  testWidgets('盘上真没有的那条，照旧整批拒绝——重读不是把拒绝一起取消',
      (tester) async {
    await pump(tester, taskWith([101]));
    writeToDisk(taskWith([101, 102]));

    final id = writeAgentRequest(
      dataDir: dataDir,
      taskId: 'rv1',
      kind: 'review.drop',
      payload: const {
        'decisions': [
          {'unit': 0, 'shot': null, 'material': 102, 'keep': false},
          {'unit': 0, 'shot': null, 'material': 999, 'keep': false}
        ]
      },
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final result = await waitForAgentRequest(
        dataDir: dataDir,
        taskId: 'rv1',
        id: id,
        timeout: const Duration(milliseconds: 100));
    expect(result!.ok, isFalse);
    expect(result.message, contains('999'));
    expect(find.text('已剔除'), findsNothing, reason: '整批拒绝，合法的那条也不做');
  });

  testWidgets('盘上没人动过就不白重读一遍——指纹没变，照旧用手上这份',
      (tester) async {
    await pump(tester, taskWith([101]));
    final readsBefore = repo.reads;

    final id = writeAgentRequest(
      dataDir: dataDir,
      taskId: 'rv1',
      kind: 'review.drop',
      payload: jsonDecode(drop(101)) as Map<String, dynamic>,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    final result = await waitForAgentRequest(
        dataDir: dataDir,
        taskId: 'rv1',
        id: id,
        timeout: const Duration(milliseconds: 100));
    expect(result!.ok, isTrue);
    expect(repo.reads, readsBefore, reason: '指纹没变就没有要重读的东西');
  });
}

class _Repo implements TaskRepository {
  final Map<String, RenewTask> tasks = {};
  int reads = 0;

  @override
  Future<List<RenewTask>> findAll() async => tasks.values.toList();

  @override
  Future<RenewTask?> findById(String id) async {
    reads++;
    return tasks[id];
  }

  @override
  Future<void> save(RenewTask task) async => tasks[task.id] = task;

  @override
  Future<void> delete(String id) async => tasks.remove(id);
}

class _FakeHoverPlayer implements ReviewHoverPlayer {
  @override
  Future<void> play(String path, {int? startMs, int? endMs}) async {}

  @override
  Future<void> stop() async {}

  @override
  Widget buildVideo() => const SizedBox.shrink();

  @override
  void dispose() {}
}

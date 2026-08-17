import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/task_lock.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/review/review_hover_player.dart';
import 'package:ishkafel/features/review/review_page.dart';
import 'package:ishkafel/features/settings/settings_providers.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

class _Repo implements TaskRepository {
  final Map<String, RenewTask> tasks = {};

  @override
  Future<List<RenewTask>> findAll() async => tasks.values.toList();

  @override
  Future<RenewTask?> findById(String id) async => tasks[id];

  @override
  Future<void> save(RenewTask task) async => tasks[task.id] = task;

  @override
  Future<void> delete(String id) async => tasks.remove(id);
}

/// 审核页：人把关那一环的 GUI 半边。
///
/// 盯的是契约行为：默认全保留、剔除落进任务、回执落盘、Agent 占锁时不硬写。
void main() {
  late Directory dataDir;
  late _Repo repo;

  RenewTask taskWith(List<UnitReplacement> replacements) => RenewTask(
        id: 'rv1',
        name: '滴露',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 17),
        updatedAt: DateTime.utc(2026, 8, 17),
        units: const [
          SemanticUnit(index: 0, startMs: 0, endMs: 5000, transcript: '第一句'),
          SemanticUnit(
              index: 1,
              startMs: 5000,
              endMs: 9000,
              transcript: '第二句',
              shots: [Shot(startMs: 5000, endMs: 9000)]),
        ],
        replacements: replacements,
        pickedMaterials: const [
          PickedMaterial(
              id: 101,
              name: '滴露_姚瑶_001',
              voiceover: '',
              sceneDescription: '',
              durationMs: 4500),
          PickedMaterial(
              id: 102,
              name: '滴露_姚瑶_002',
              voiceover: '',
              sceneDescription: ''),
        ],
      );

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('review_page_');
    repo = _Repo();
  });
  tearDown(() => dataDir.deleteSync(recursive: true));

  // 1×1 透明 PNG：Image.file 在测试里会真的解码，得给一张合法的图
  const png = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ];

  Future<String?> extractThumb(int startMs, int endMs) async {
    final file = File('${dataDir.path}/thumb_${startMs}_$endMs.png')
      ..writeAsBytesSync(png);
    return file.path;
  }

  Object? popped;

  Future<void> pump(WidgetTester tester, RenewTask task) async {
    repo.tasks[task.id] = task;
    popped = null;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dataDirProvider.overrideWithValue(dataDir),
        taskRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        // 审核页确认后 pop 回来处——用一个真实的 push 才能接到返回值
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  popped = await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ReviewPage(
                        task: task,
                        hoverPlayer: _FakeHoverPlayer(),
                        resolveMedia: (_) async => '/tmp/fake.mp4',
                        extractOriginalThumb: extractThumb,
                      ),
                    ),
                  );
                },
                child: const Text('进入审核'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('进入审核'));
    // 把路由动画走完：动画中页面整体右偏，右下角的确认按钮会在视口外
    await tester.pumpAndSettle();
  }

  testWidgets('候选按位置分组列出，默认全部保留', (tester) async {
    await pump(
        tester,
        taskWith([
          UnitReplacement.whole(const [101, 102]),
          UnitReplacement.perShot(const {
            0: [101]
          }),
        ]));

    // 左栏与正文各出现一次
    expect(find.text('U1 · 整段替换'), findsNWidgets(2));
    expect(find.text('U2 · S1'), findsNWidgets(2));
    expect(find.textContaining('保留 3 · 剔除 0'), findsOneWidget);
    expect(find.text('第一句'), findsOneWidget, reason: '台词给上下文');
    // 每个位置组开头是原片卡：审核是「原来是什么 → 换成什么」的对比
    expect(find.text('原片'), findsNWidgets(2));
    expect(find.byIcon(Icons.arrow_forward), findsNWidgets(2));
    // 原片卡显示这一段的真实首帧，不是占位图标
    await tester.pump();
    expect(find.byKey(const Key('review-original-thumb-0/null')),
        findsOneWidget);
  });

  testWidgets('取消勾选 → 确认：剔除落进任务、回执落盘', (tester) async {
    await pump(tester, taskWith([UnitReplacement.whole(const [101, 102])]));

    // 点卡片即剔除——审核是把不要的挑出来，不摆一排勾选框
    await tester.tap(find.byKey(const Key('review-card-0/null/101')));
    await tester.pump();
    expect(find.text('已剔除'), findsOneWidget);
    expect(find.textContaining('保留 1 · 剔除 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('review-confirm')));
    await tester.pumpAndSettle();

    // 任务：101 被剔掉——主流程即结果，没有回执这层中间产物
    expect(repo.tasks['rv1']!.replacements![0].wholeCandidateIds, [102]);
    // 确认后回到来处，带上结果给来处弹条用——审核页不是终点站
    expect(find.byKey(const Key('review-confirm')), findsNothing);
    expect((popped as ReviewOutcome).dropped, 1);
    expect((popped as ReviewOutcome).kept, 1);
  });

  testWidgets('原片卡点了不剔除——它是参照物，不是候选', (tester) async {
    await pump(tester, taskWith([UnitReplacement.whole(const [101])]));
    await tester.tap(find.byKey(const Key('review-original-0/null')));
    await tester.pump();
    expect(find.text('已剔除'), findsNothing);
    expect(find.textContaining('剔除 0'), findsOneWidget);
  });

  testWidgets('空白任务没有原片，不显示原片卡', (tester) async {
    final task = taskWith([UnitReplacement.whole(const [101])]);
    await pump(
        tester,
        RenewTask(
          id: task.id,
          name: task.name,
          sourcePath: null,
          status: task.status,
          createdAt: task.createdAt,
          updatedAt: task.updatedAt,
          units: task.units,
          replacements: task.replacements,
          pickedMaterials: task.pickedMaterials,
        ));
    expect(find.text('原片'), findsNothing);
  });

  testWidgets('一条候选都没有时说清，不摆确认按钮', (tester) async {
    await pump(tester, taskWith([UnitReplacement.keepOriginal()]));
    expect(find.textContaining('没有可审核的'), findsOneWidget);
    expect(find.byKey(const Key('review-confirm')), findsNothing);
  });

  testWidgets('Agent 占着锁时**进门就拦**，给强制接管——互斥是会话级的', (tester) async {
    // 只在确认那一刻抢锁是补丁：审核期间任务不设防，Agent 中途改方案
    // 会让确认剪的是过期状态
    final lock = TaskLockFile(dataDir: dataDir, taskId: 'rv1');
    lock.acquire('agent');

    await pump(tester, taskWith([UnitReplacement.whole(const [101])]));

    expect(find.textContaining('agent 正在操作这个任务'), findsOneWidget);
    expect(find.byKey(const Key('review-confirm')), findsNothing,
        reason: '被拦时不该出现确认按钮');

    // 强制接管后照常进入
    await tester.tap(find.byKey(const Key('review-takeover')));
    await tester.pump();
    expect(find.byKey(const Key('review-confirm')), findsOneWidget);
  });

  testWidgets('独立模式进门持锁——审核期间 Agent 的写入会被拒', (tester) async {
    await pump(tester, taskWith([UnitReplacement.whole(const [101])]));
    final lock = TaskLockFile(dataDir: dataDir, taskId: 'rv1');
    expect(lock.acquire('agent'), isFalse, reason: '人在审核，Agent 拿不到锁');
  });
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

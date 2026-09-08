import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/agent_request.dart';
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
          SemanticUnit(
              index: 0,
              startMs: 0,
              endMs: 5000,
              transcript: '第一句',
              tags: ['促单', '痛点']),
          SemanticUnit(
              index: 1,
              startMs: 5000,
              endMs: 9000,
              transcript: '第二句',
              shots: [
                Shot(startMs: 5000, endMs: 9000, tags: ['厨房情景', '实拍'])
              ]),
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
    // 测试默认视口只有 800×600，段落头里摆着完整的标签与不截断的台词，
    // 两组就挤不下了——而真机窗口远比这大。按实际尺寸给，别为了迁就
    // 一个假窗口把界面改回去截断
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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

  testWidgets('段落上把这一层的标签摆出来：整段替换给单元标签，逐镜头给镜头标签',
      (tester) async {
    // 标签就是这一段的检索键。人在审核候选「像不像」的时候，得能看见
    // 它当初是按什么搜出来的——看不见就只能猜，猜不对就只会反复剔除
    await pump(
        tester,
        taskWith([
          UnitReplacement.whole(const [101]),
          UnitReplacement.perShot(const {
            0: [102]
          }),
        ]));

    // U1 是整段替换 → 单元标签
    expect(find.text('促单'), findsOneWidget);
    expect(find.text('痛点'), findsOneWidget);
    // U2·S1 是镜头替换 → 那个镜头的标签
    expect(find.text('厨房情景'), findsOneWidget);
    expect(find.text('实拍'), findsOneWidget);
  });

  testWidgets('内嵌模式改标签交回工作台，自己不写盘（两边都整份落库，谁后写谁赢）',
      (tester) async {
    List<SemanticUnit>? handedBack;
    final task = taskWith([UnitReplacement.whole(const [101])]);
    repo.tasks[task.id] = task;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        dataDirProvider.overrideWithValue(dataDir),
        taskRepositoryProvider.overrideWithValue(repo),
      ],
      child: MaterialApp(
        home: ReviewPage(
          task: task,
          onApply: (_) {},
          onTagsChanged: (units) => handedBack = units,
          hoverPlayer: _FakeHoverPlayer(),
          resolveMedia: (_) async => '/tmp/fake.mp4',
          extractOriginalThumb: extractThumb,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 「改标签」入口在每个段落上
    expect(find.byKey(const ValueKey('review-edit-tags-0/null')),
        findsOneWidget);
    expect(handedBack, isNull, reason: '没改之前不该往外抛');
  });

  testWidgets('台词整段显示，不截断也不加省略号', (tester) async {
    // 人正是靠这段台词判断候选贴不贴题。截成两行加「…」等于把要判断的
    // 东西藏起来——省下的那点高度换不来这个
    await pump(tester, taskWith([UnitReplacement.whole(const [101])]));

    final text = tester.widget<Text>(find.text('第一句'));
    expect(text.maxLines, isNull, reason: '不许限行数');
    expect(text.overflow, isNot(TextOverflow.ellipsis), reason: '不许省略号');
  });

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

  testWidgets('另一个窗口占着锁时**进门就拦**，给强制接管——互斥是会话级的',
      (tester) async {
    // 只在确认那一刻抢锁是补丁：审核期间任务不设防，别人中途改方案
    // 会让确认剪的是过期状态
    final lock = TaskLockFile(dataDir: dataDir, taskId: 'rv1');
    lock.acquire('gui:$pid');

    await pump(tester, taskWith([UnitReplacement.whole(const [101])]));

    expect(find.textContaining('gui:$pid 正在操作这个任务'), findsOneWidget);
    expect(find.byKey(const Key('review-confirm')), findsNothing,
        reason: '被拦时不该出现确认按钮');

    // 强制接管后照常进入
    await tester.tap(find.byKey(const Key('review-takeover')));
    await tester.pumpAndSettle();
    // 抢锁是破坏性的（对方之后的写入被拒），必须先过确认框
    expect(find.text('强制接管这个任务？'), findsOneWidget);
    await tester.tap(find.text('接管'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-confirm')), findsOneWidget);
  });

  /// Agent 持锁时**不拦成一张空白页**——可视模式下人正是为了看它干活才
  /// 把这页打开的。拦成空白页等于把要看的东西挡在门外
  testWidgets('Agent 占着锁：照常显示候选，只读、并说清它在做什么',
      (tester) async {
    TaskLockFile(dataDir: dataDir, taskId: 'rv1').acquire('Agent');
    writeAgentPresence(
      dataDir: dataDir,
      taskId: 'rv1',
      presence: AgentPresence(
        holder: 'Agent',
        at: DateTime.now(),
        action: '正在剔除第 1 段的素材 101',
        step: 1,
        focus: const AgentFocus(
            module: 'review', lineIndex: 0, unitIndex: 0, materialId: 101),
      ),
    );

    await pump(tester, taskWith([UnitReplacement.whole(const [101, 102])]));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // 候选照常在，人能看见它在动什么
    expect(find.byKey(const Key('review-card-0/null/101')), findsOneWidget);
    expect(find.textContaining('正在剔除第 1 段的素材 101'), findsOneWidget);

    // 只读：点了不生效
    await tester.tap(find.byKey(const Key('review-card-0/null/101')));
    await tester.pump();
    expect(find.text('已剔除'), findsNothing);

    // 展示完要回执，Agent 靠它决定什么时候走下一步
    await tester.pump(const Duration(milliseconds: 600));
    expect(readAgentAck(dataDir: dataDir, taskId: 'rv1'), 1);
  });

  /// 人正开着审片台指挥 Agent：界面持锁，Agent 把活儿**委派**过来。
  /// 剔除是界面里的临时状态，人按确认才落盘——所以必须由界面执行
  group('人在场时替人代办', () {
    testWidgets('Agent 下单剔除：卡片当场变成已剔除，并回执', (tester) async {
      await pump(
          tester, taskWith([UnitReplacement.whole(const [101, 102])]));

      final id = writeAgentRequest(
        dataDir: dataDir,
        taskId: 'rv1',
        kind: 'review.drop',
        payload: const {
          'decisions': [
            {'unit': 0, 'shot': null, 'material': 101, 'keep': false}
          ]
        },
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      expect(find.text('已剔除'), findsOneWidget);
      expect(find.textContaining('保留 1 · 剔除 1'), findsOneWidget);
      // 盘上不能变——人还没按确认
      expect(repo.tasks['rv1']!.replacements![0].wholeCandidateIds,
          const [101, 102]);
      // 回执要带上做了什么
      final result = await waitForAgentRequest(
          dataDir: dataDir, taskId: 'rv1', id: id,
          timeout: const Duration(milliseconds: 100));
      expect(result!.ok, isTrue);
      expect(result.message, contains('1'));
    });

    testWidgets('下单里有界面上没有的卡：整批不做，回执说清原因', (tester) async {
      await pump(tester, taskWith([UnitReplacement.whole(const [101, 102])]));

      final id = writeAgentRequest(
        dataDir: dataDir,
        taskId: 'rv1',
        kind: 'review.drop',
        payload: const {
          'decisions': [
            {'unit': 0, 'shot': null, 'material': 101, 'keep': false},
            {'unit': 9, 'shot': null, 'material': 999, 'keep': false}
          ]
        },
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      // 合法的那条也不做：整批拒绝，不然人以为删了两条实际删了一条
      expect(find.text('已剔除'), findsNothing);
      final result = await waitForAgentRequest(
          dataDir: dataDir, taskId: 'rv1', id: id,
          timeout: const Duration(milliseconds: 100));
      expect(result!.ok, isFalse);
      expect(result.message, contains('999'));
    });

    testWidgets('恢复：把剔掉的标回来', (tester) async {
      await pump(tester, taskWith([UnitReplacement.whole(const [101, 102])]));
      await tester.tap(find.byKey(const Key('review-card-0/null/101')));
      await tester.pump();
      expect(find.text('已剔除'), findsOneWidget);

      writeAgentRequest(
        dataDir: dataDir,
        taskId: 'rv1',
        kind: 'review.keep',
        payload: const {
          'decisions': [
            {'unit': 0, 'shot': null, 'material': 101, 'keep': true}
          ]
        },
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('已剔除'), findsNothing);
    });
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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/storage/task_repository.dart';
import 'package:ishkafel/features/picking/picking_page.dart';
import 'package:ishkafel/features/picking/picking_widgets.dart';
import 'package:ishkafel/features/tasks/task_list_controller.dart';

class _InMemoryRepo implements TaskRepository {
  final Map<String, RenewTask> store = {};

  @override
  Future<List<RenewTask>> findAll() async => store.values.toList();

  @override
  Future<RenewTask?> findById(String id) async => store[id];

  @override
  Future<void> save(RenewTask task) async => store[task.id] = task;

  @override
  Future<void> delete(String id) async => store.remove(id);
}

RenewTask _task({
  List<TagGroupRef> shotTagGroups = const [],
  List<UnitReplacement>? replacements,
  List<String> shotTags = const ['厨房', '特写'],
}) =>
    RenewTask(
      id: 'p1',
      name: '滴露_植源喷雾',
      sourcePath: '/tmp/a.mp4',
      status: RenewTaskStatus.picking,
      createdAt: DateTime.utc(2026, 7, 30),
      updatedAt: DateTime.utc(2026, 7, 30),
      shotTagGroups: shotTagGroups,
      replacements: replacements,
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(seconds: 30),
          fps: 30,
          fileSizeBytes: 1),
      units: [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 9000,
          transcript: '衣服洗完还是有异味',
          shots: [
            Shot(startMs: 0, endMs: 4000, tags: shotTags),
            const Shot(startMs: 4000, endMs: 9000),
          ],
        ),
        const SemanticUnit(
          index: 1,
          startMs: 9000,
          endMs: 26000,
          transcript: '滴露植源喷雾',
          shots: [Shot(startMs: 9000, endMs: 26000)],
        ),
      ],
    );

String _searchJson(int count) => jsonEncode({
      'total': count,
      'records': [
        for (var i = 0; i < count; i++)
          {
            'id': 100 + i,
            'name': '候选$i',
            'sceneDescription': '画面$i',
            'mediaFile': {
              'thumbnailUrl': 'https://example.com/$i.jpg',
              'previewUrl': 'https://example.com/$i.mp4',
              'fileKey': 'oss/$i.mp4',
            },
          },
      ],
    });

const _probeStdout = 'width=1080\nheight=1920\nduration=6.840000\n';

/// miaoa 标签表的假返回：标签名 → id 的映射来源
final String _tagListJson = jsonEncode([
  {'id': 71, 'tagName': '厨房'},
  {'id': 72, 'tagName': '特写'},
]);

typedef _Run = Future<ProcessResult> Function(String, List<String>);

Future<void> _pump(
  WidgetTester tester, {
  required RenewTask task,
  required TaskRepository repo,
  required PlaybackController playback,
  _Run? search,
  _Run? probe,
  _Run? tags,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(ProviderScope(
    overrides: [taskRepositoryProvider.overrideWithValue(repo)],
    child: MaterialApp(
      home: PickingPage(
        task: task,
        playbackFactory: () => playback,
        contentService: MiaoaContentService(
            run: search ?? (_, _) async => ProcessResult(1, 0, _searchJson(3), '')),
        candidateProbe: CandidateProbe(
            run: probe ?? (_, _) async => ProcessResult(1, 0, _probeStdout, '')),
        tagService: MiaoaTagService(
            run: tags ?? (_, _) async => ProcessResult(1, 0, _tagListJson, '')),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  late _InMemoryRepo repo;
  late FakePlaybackController playback;

  setUp(() {
    repo = _InMemoryRepo();
    playback = FakePlaybackController();
  });

  group('页面骨架', () {
    testWidgets('三栏 + 单元导航 + 组合数状态栏都在', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);

      expect(find.byKey(const Key('picking-unit-row-0')), findsOneWidget);
      expect(find.byKey(const Key('picking-unit-row-1')), findsOneWidget);
      expect(find.byKey(const Key('picking-nav-0')), findsOneWidget);
      expect(find.byKey(const Key('picking-combination-status')), findsOneWidget);
      expect(find.byKey(const Key('picking-back-to-cut')), findsOneWidget);
      expect(find.byKey(const Key('picking-enter-export')), findsOneWidget);
      expect(find.textContaining('台词语义单元'), findsWidgets);
    });

    testWidgets('刚进来一条替换都没设置：状态栏提醒导出结果与原片相同', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      expect(find.textContaining('与原片相同'), findsOneWidget);
    });

    testWidgets('左栏徽标区分三种模式（整体 / 镜头级 / 保留原片）', (tester) async {
      await _pump(
        tester,
        task: _task(replacements: [
          UnitReplacement.whole([1, 2]),
          UnitReplacement.keepOriginal(),
        ]),
        repo: repo,
        playback: playback,
      );
      expect(find.text('整体 ×2'), findsWidgets);
      expect(find.text('保留原片'), findsWidgets);
    });
  });

  group('替换模式三态互斥', () {
    testWidgets('进入镜头级后整体替换显示锁定态并禁用', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);

      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();
      // 只有选过候选之后另一边才锁（还没选时用户要能反悔）
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      final whole = tester.widget<IgnorePointer>(find
          .ancestor(
            of: find.byKey(const Key('picking-mode-whole')),
            matching: find.byType(IgnorePointer),
          )
          .first);
      expect(whole.ignoring, isTrue, reason: '锁定态必须真的点不动，不能只是画个锁');
      expect(find.byKey(const Key('picking-mode-lock-hint')), findsOneWidget);
    });

    testWidgets('镜头条按视觉镜头列出，各带自己的因子', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('picking-shot-0')), findsOneWidget);
      expect(find.byKey(const Key('picking-shot-1')), findsOneWidget);
      expect(find.text('S1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.tap(find.byKey(const Key('picking-candidate-101')));
      await tester.pumpAndSettle();
      expect(find.text('×2'), findsWidgets);
    });

    testWidgets('没有视觉镜头的单元：镜头替换禁用并说明原因', (tester) async {
      final task = RenewTask(
        id: 'p2',
        name: 'n',
        sourcePath: '/tmp/a.mp4',
        status: RenewTaskStatus.picking,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        videoInfo: const VideoInfo(
            width: 1080,
            height: 1920,
            duration: Duration(seconds: 9),
            fps: 30,
            fileSizeBytes: 1),
        units: const [
          SemanticUnit(index: 0, startMs: 0, endMs: 9000, transcript: '只有一句台词'),
        ],
      );
      await _pump(tester, task: task, repo: repo, playback: playback);
      expect(find.byKey(const Key('picking-no-shot-hint')), findsOneWidget);
    });
  });

  group('候选素材面板', () {
    testWidgets('勾选多选并实时更新因子小结与组合数', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.tap(find.byKey(const Key('picking-candidate-101')));
      await tester.pumpAndSettle();

      expect(find.textContaining('已选 2 / 3 条'), findsOneWidget);
      expect(find.textContaining('= 2 条'), findsOneWidget);
    });

    testWidgets('规格探测未完成时显示「探测中」占位，不是空白', (tester) async {
      await _pump(
        tester,
        task: _task(),
        repo: repo,
        playback: playback,
        probe: (_, _) async {
          await Future<void>.delayed(const Duration(seconds: 10));
          return ProcessResult(1, 0, _probeStdout, '');
        },
      );
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('探测中'), findsWidgets);
      // 收尾：让挂起的探测走完，避免测试结束时留下未完成的定时器
      await tester.pumpAndSettle(const Duration(seconds: 11));
    });

    testWidgets('探测失败的候选不显示时长差徽标（不拿假数据糊弄）', (tester) async {
      await _pump(
        tester,
        task: _task(),
        repo: repo,
        playback: playback,
        probe: (_, _) async => ProcessResult(1, 1, '', 'boom'),
      );
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();

      expect(find.text('探测中'), findsNothing);
      expect(find.byKey(const Key('picking-duration-delta-100')), findsNothing);
    });

    testWidgets('检索失败：原样透出服务层中文，不加「未知错误」壳', (tester) async {
      await _pump(
        tester,
        task: _task(),
        repo: repo,
        playback: playback,
        search: (_, _) async => ProcessResult(1, 1, '', 'HTTP 401 unauthorized'),
      );
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();

      expect(find.textContaining('miaoa auth login'), findsOneWidget);
      expect(find.textContaining('未知'), findsNothing);
    });

    testWidgets('检索 0 条：标签模式下按「有没有打标签」给不同引导', (tester) async {
      await _pump(
        tester,
        task: _task(shotTagGroups: [const TagGroupRef(id: 9, name: '画面类型')]),
        repo: repo,
        playback: playback,
        search: (_, _) async => ProcessResult(1, 0, _searchJson(0), ''),
      );
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();

      // S1 有标签 → 是素材库里确实没有
      expect(find.textContaining('放宽'), findsOneWidget);

      // S2 没有标签 → 是标签没打上
      await tester.tap(find.byKey(const Key('picking-shot-1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有打上标签'), findsOneWidget);
    });

    testWidgets('任务没选视觉镜头标签组：标签检索禁用并说明为什么', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();

      final tagSeg = tester.widget<IgnorePointer>(find
          .ancestor(
            of: find.byKey(const Key('picking-search-tag')),
            matching: find.byType(IgnorePointer),
          )
          .first);
      expect(tagSeg.ignoring, isTrue);
      expect(find.textContaining('没有为视觉镜头选择标签组'), findsOneWidget);
    });
  });

  group('进入矩阵导出（阶段③）', () {
    testWidgets('组合数超限：按钮禁用并说清超了多少、该从哪减', (tester) async {
      await _pump(
        tester,
        task: _task(replacements: [
          UnitReplacement.whole(List.generate(11, (i) => i)),
          UnitReplacement.whole(List.generate(11, (i) => 100 + i)),
        ]),
        repo: repo,
        playback: playback,
      );

      final button =
          tester.widget<FilledButton>(find.byKey(const Key('picking-enter-export')));
      expect(button.onPressed, isNull);
      expect(find.textContaining('超出上限'), findsOneWidget);
      expect(find.textContaining('U1'), findsWidgets);
    });

    testWidgets('未超限：按钮可点，但如实说明阶段③尚未开放（不留没解释的死按钮）',
        (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);

      final button =
          tester.widget<FilledButton>(find.byKey(const Key('picking-enter-export')));
      expect(button.onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('picking-enter-export')));
      await tester.pumpAndSettle();
      expect(find.textContaining('尚未开放'), findsOneWidget);
    });
  });

  group('替换方案落库', () {
    testWidgets('点「进入矩阵导出」时先把方案存下来', (tester) async {
      await repo.save(_task());
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('picking-enter-export')));
      await tester.pumpAndSettle();

      final saved = await repo.findById('p1');
      expect(saved!.replacements!.first.wholeCandidateIds, [100]);
    });

    testWidgets('落库失败要让用户看见，不能点了没反应', (tester) async {
      await _pump(
        tester,
        task: _task(),
        repo: _FailingRepo(),
        playback: playback,
      );
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('picking-enter-export')));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
    });
  });

  group('播放器：原片 ⇄ 候选预览', () {
    testWidgets('进入页面先开原片', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      expect(playback.calls, contains('open(/tmp/a.mp4)'));
    });

    testWidgets('选中候选后切到候选预览，播放器打开候选的预览地址', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('picking-preview-candidate')));
      await tester.pumpAndSettle();
      expect(playback.calls, contains('open(https://example.com/0.mp4)'));
    });

    testWidgets('没有选中候选时「候选预览」禁用并说明原因', (tester) async {
      await _pump(tester, task: _task(), repo: repo, playback: playback);
      final seg = tester.widget<IgnorePointer>(find
          .ancestor(
            of: find.byKey(const Key('picking-preview-candidate')),
            matching: find.byType(IgnorePointer),
          )
          .first);
      expect(seg.ignoring, isTrue);
    });
  });

  _searchModeRegressions();
}

class _FailingRepo implements TaskRepository {
  @override
  Future<List<RenewTask>> findAll() async => const [];

  @override
  Future<RenewTask?> findById(String id) async => null;

  @override
  Future<void> save(RenewTask task) async => throw const FileSystemException('磁盘满');

  @override
  Future<void> delete(String id) async {}
}

void _searchModeRegressions() {
  group('检索方式的默认选中（真机验收发现）', () {
    testWidgets('标签不可用时，进页面就不该把「标签」选中着', (tester) async {
      final repo = _InMemoryRepo();
      final task = _task(shotTagGroups: const []); // 建任务时没选视觉镜头标签组
      repo.store[task.id] = task;

      await _pump(
          tester,
          task: task,
          repo: repo,
          playback: FakePlaybackController());

      final segmented = tester.widget<PickingSegmented>(find
          .ancestor(
              of: find.byKey(const Key('picking-search-tag')),
              matching: find.byType(PickingSegmented))
          .first);

      expect(segmented.selectedIndex,
          isNot(CandidateSearchMode.values.indexOf(CandidateSearchMode.tag)),
          reason: '「标签」这一段是点不动的（没有标签组就没有检索键）。'
              '把一个点不动的段画成选中态，用户只会盯着一个永远空白的候选面板，'
              '既不知道为什么，也不知道该点哪儿');
      expect(
          segmented.selectedIndex,
          CandidateSearchMode.values
              .indexOf(CandidateSearchMode.description),
          reason: '应当自动落到「画面描述」——它是此时唯一能用的检索方式');
    });

    testWidgets('标签可用时仍然默认选「标签」', (tester) async {
      final repo = _InMemoryRepo();
      final task = _task(shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')]);
      repo.store[task.id] = task;

      await _pump(
          tester,
          task: task,
          repo: repo,
          playback: FakePlaybackController());

      final segmented = tester.widget<PickingSegmented>(find
          .ancestor(
              of: find.byKey(const Key('picking-search-tag')),
              matching: find.byType(PickingSegmented))
          .first);

      expect(segmented.selectedIndex,
          CandidateSearchMode.values.indexOf(CandidateSearchMode.tag),
          reason: '标签检索是主路径，能用时就该是默认');
    });

    testWidgets('标签表拉取失败后也要让出选中态', (tester) async {
      final repo = _InMemoryRepo();
      final task = _task(shotTagGroups: [const TagGroupRef(id: 136, name: '画面类型')]);
      repo.store[task.id] = task;

      await _pump(
        tester,
        task: task,
        repo: repo,
        playback: FakePlaybackController(),
        tags: (_, _) async => ProcessResult(1, 1, '', '401 Unauthorized'),
      );

      final segmented = tester.widget<PickingSegmented>(find
          .ancestor(
              of: find.byKey(const Key('picking-search-tag')),
              matching: find.byType(PickingSegmented))
          .first);

      expect(segmented.selectedIndex,
          isNot(CandidateSearchMode.values.indexOf(CandidateSearchMode.tag)),
          reason: '标签表是异步拉的：进页面时还可用、拉完才发现不可用，'
              '这一刻同样不能把点不动的段留在选中态');
    });
  });
}

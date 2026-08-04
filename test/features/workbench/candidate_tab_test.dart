import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/project_ref.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/workbench/candidate_tab.dart';

/// 假素材库：记录每次检索用的标签 id，便于断言「作用域跟着工作台的选中走」
class _FakeContentService implements MiaoaContentService {
  final tagQueries = <List<int>>[];
  final keywordQueries = <String>[];
  final projectQueries = <List<int>>[];

  @override
  Future<CandidatePage> searchByTags({
    required List<int> tagIds,
    String mode = 'or',
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    tagQueries.add(List.of(tagIds));
    projectQueries.add(List.of(projectIds));
    return CandidatePage(items: const [], total: 0, skipped: 0);
  }

  @override
  Future<CandidatePage> searchByDescription({
    required String keyword,
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    keywordQueries.add(keyword);
    projectQueries.add(List.of(projectIds));
    return CandidatePage(items: const [], total: 0, skipped: 0);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTagService implements MiaoaTagService {
  final Map<int, List<TagInfo>> byGroup;
  _FakeTagService(this.byGroup);

  @override
  Future<List<TagInfo>> listTags(int groupId) async => byGroup[groupId] ?? [];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 两个单元，各两个镜头，镜头标签各不相同——检索键能唯一指认是哪个作用域
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句台词',
        tags: ['促单', '辅助卖点'],
        shots: [
          Shot(startMs: 0, endMs: 1000, tags: ['近景']),
          Shot(startMs: 1000, endMs: 2000, tags: ['中景']),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句台词',
        tags: ['主卖点解决方案'],
        shots: [
          Shot(startMs: 2000, endMs: 3000, tags: ['远景']),
          Shot(startMs: 3000, endMs: 4000, tags: ['特写']),
        ],
      ),
    ];

/// 画面层（视觉镜头标签组 id=1）与台词语义层（标签组 id=2）各一套
const _tagIds = {'近景': 11, '中景': 12, '远景': 13, '特写': 14};
const _unitTagIds = {'促单': 21, '辅助卖点': 22, '主卖点解决方案': 23};

Future<(SegmentationEditorController, _FakeContentService)> _pump(
  WidgetTester tester, {
  List<UnitReplacement>? initial,
  List<UnitReplacement>? Function(List<UnitReplacement>)? onSave,
  ProjectRef? project,
}) async {
  final editor = SegmentationEditorController(
    initialUnits: _units(),
    durationMs: 4000,
    fps: 30,
    sentences: const [],
  );
  final content = _FakeContentService();
  final tags = _FakeTagService({
    1: [for (final e in _tagIds.entries) TagInfo(id: e.value, name: e.key)],
    2: [
      for (final e in _unitTagIds.entries) TagInfo(id: e.value, name: e.key)
    ],
  });

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 320,
        height: 700,
        child: CandidateTab(
          editor: editor,
          shotTagGroups: const [TagGroupRef(id: 1, name: '视觉镜头标签')],
          unitTagGroups: const [TagGroupRef(id: 2, name: '台词语义单元标签')],
          initialReplacements: initial,
          project: project,
          onReplacementsChanged: (r) => onSave?.call(r),
          contentService: content,
          tagService: tags,
          candidateProbe: CandidateProbe(run: (_, _) async => throw 'no probe'),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (editor, content);
}

/// 默认是「保持原片」——此时不该打网络（没在替换，检索什么都是白检）。
/// 要看到候选，先选一种替换方式。
Future<void> _chooseWhole(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('picking-mode-whole')));
  await tester.pumpAndSettle();
}

void main() {
  _projectScope();

  group('候选面板跟着工作台的选中走，不自己维护一份', () {
    testWidgets('在时间线上选中另一个单元，检索键跟着换', (tester) async {
      final (editor, content) = await _pump(tester);

      editor.select(const EditorSelection.unit(0));
      await tester.pumpAndSettle();
      await _chooseWhole(tester);
      // 整体替换用这个台词语义单元自己的标签，不是它那几个镜头标签的并集
      expect(content.tagQueries.last, unorderedEquals([21, 22]));

      editor.select(const EditorSelection.unit(1));
      await tester.pumpAndSettle();
      await _chooseWhole(tester);

      expect(content.tagQueries.last, unorderedEquals([23]),
          reason: '右栏是同一个工作台的另一个视图：时间线上选中谁，'
              '就是在给谁挑素材，不该还要在右栏里再选一次');
    });

    testWidgets('选中某个视觉镜头时，作用域收窄到那个镜头', (tester) async {
      final (editor, content) = await _pump(tester);

      editor.select(const EditorSelection.shot(1, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();

      expect(content.tagQueries.last, [14],
          reason: '选中 S 时只该用这个镜头的标签检索，'
              '用整个单元的并集会检出一堆和这个镜头无关的素材');
    });

    testWidgets('挂载时就读当前选中，而不是从 U1 开始', (tester) async {
      // 右栏切回「替换素材」时面板是重新挂载的。只订阅「之后的变化」，
      // 就会显示成用户在别处早已经离开的那个单元。
      final editor = SegmentationEditorController(
        initialUnits: _units(),
        durationMs: 4000,
        fps: 30,
        sentences: const [],
      );
      editor.select(const EditorSelection.unit(1));

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 700,
            child: CandidateTab(
              editor: editor,
              shotTagGroups: const [],
              onReplacementsChanged: (_) {},
              contentService: _FakeContentService(),
              tagService: _FakeTagService(const {}),
              candidateProbe:
                  CandidateProbe(run: (_, _) async => throw 'no probe'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('U2 · 候选素材'), findsOneWidget);
    });

    testWidgets('保持原片时不打网络', (tester) async {
      final (editor, content) = await _pump(tester);

      editor.select(const EditorSelection.unit(0));
      await tester.pumpAndSettle();

      expect(content.tagQueries, isEmpty,
          reason: '本单元不替换，检索出来的候选没有任何用处');
    });

    testWidgets('同一个作用域不重复打网络', (tester) async {
      final (editor, content) = await _pump(tester);

      editor.select(const EditorSelection.unit(1));
      await tester.pumpAndSettle();
      await _chooseWhole(tester);
      final count = content.tagQueries.length;

      // 编辑器因别的原因 notify（如播放头移动引发的重建）不该再检索一次
      editor.select(const EditorSelection.unit(1));
      await tester.pumpAndSettle();

      expect(content.tagQueries.length, count);
    });
  });

  group('落库', () {
    testWidgets('改了替换方案就交回工作台落库，不需要用户点保存', (tester) async {
      final saved = <List<UnitReplacement>>[];
      final (editor, _) = await _pump(tester, onSave: (r) {
        saved.add(r);
        return null;
      });

      editor.select(const EditorSelection.unit(0));
      await tester.pumpAndSettle();
      await _chooseWhole(tester);

      expect(saved, isNotEmpty,
          reason: '工作台里每次改动都直接落库，选材同理');
      expect(saved.last[0].mode, ReplacementMode.whole);
    });
  });

  _workbenchIntegration();
}

/// 真机回归：在完整的工作台里（右栏是 tab、候选面板由页面装配后传下来），
/// 点左栏单元行换选中，候选面板必须跟着换。
/// 单独 pump CandidateTab 的用例覆盖不到「页面装配」这一层。
void _workbenchIntegration() {
  testWidgets('装进工作台右栏后，点单元行候选面板跟着换', (tester) async {
    final editor = SegmentationEditorController(
      initialUnits: _units(),
      durationMs: 4000,
      fps: 30,
      sentences: const [],
    );
    final content = _FakeContentService();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1200,
          height: 800,
          child: _TabHost(
            editor: editor,
            child: CandidateTab(
              editor: editor,
              shotTagGroups: const [],
              onReplacementsChanged: (_) {},
              contentService: content,
              tagService: _FakeTagService(const {}),
              candidateProbe:
                  CandidateProbe(run: (_, _) async => throw 'no probe'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('U1 · 候选素材'), findsOneWidget);

    await tester.tap(find.byKey(const Key('host-select-1')));
    await tester.pumpAndSettle();

    expect(find.text('U2 · 候选素材'), findsOneWidget,
        reason: '右栏是同一个工作台的另一个视图，选中权在时间线/单元列表');
  });
}

/// 复刻工作台的装配方式：候选面板由外层构造一次后传进来，
/// 外层本身不因选中变化而重建（选中变化只走编辑器的监听）
class _TabHost extends StatelessWidget {
  final SegmentationEditorController editor;
  final Widget child;
  const _TabHost({required this.editor, required this.child});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          TextButton(
            key: const Key('host-select-1'),
            onPressed: () => editor.select(const EditorSelection.unit(1)),
            child: const Text('选中 U2'),
          ),
          Expanded(child: SizedBox(width: 300, child: child)),
        ],
      );
}

/// 项目是「上哪儿找素材」，两种替换方式都要受它限定
void _projectScope() {
  group('检索限定在任务选的项目里', () {
    testWidgets('选了项目，替换素材就只在这个项目里找', (tester) async {
      final (editor, content) = await _pump(tester,
          project: const ProjectRef(id: 104, name: '滴露植源喷雾'));

      editor.select(const EditorSelection.unit(0));
      await tester.pumpAndSettle();
      await _chooseWhole(tester);

      expect(content.projectQueries.last, [104],
          reason: '不带项目搜出来的是别的片子的素材，用户还得自己认');
    });

    testWidgets('镜头替换同样带项目——两种替换方式都要限定范围', (tester) async {
      final (editor, content) = await _pump(tester,
          project: const ProjectRef(id: 104, name: '滴露植源喷雾'));

      editor.select(const EditorSelection.shot(0, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();

      expect(content.projectQueries.last, [104]);
    });

    testWidgets('没选项目时不限项目', (tester) async {
      final (editor, content) = await _pump(tester);

      editor.select(const EditorSelection.unit(0));
      await tester.pumpAndSettle();
      await _chooseWhole(tester);

      expect(content.projectQueries.last, isEmpty);
    });
  });
}

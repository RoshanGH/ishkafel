import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/features/workbench/candidate_tab.dart';

/// 候选面板**只能落地一次**。
///
/// 2026-09-18 真机，用户原话：「点了 U 的 S1，然后点替换这个镜头，无论是替换
/// 整段还是替换镜头，它这个镜头的搜索都会经过明显的两次跳转，然后才会跳转到
/// 真正的搜索结果上。第一次它会出现一些视频分镜，但是我不知道这些分镜是怎么
/// 来的……如果它慢的话，我接受它一个 Loading，但是我不接受它这样跳来跳去，
/// 因为中间我真的可能会选到那些。」
///
/// 两条独立的成因，各一组用例：
///
/// **一、回退判定发生在结果已经发布之后**（确定性，每次都犯）
/// `searchByTags` 一返回就把 status 置成 ready 并通知，界面立刻把那批画出来；
/// 之后才判定「标签太宽，这批没用」，再改走画面描述重搜。那批被画出来的正是
/// 「按标签搜给的是最新的、不是最像的」那一堆——也就是用户说的「不知道怎么
/// 来的分镜」，而且**那几秒里他真的能点中**。
///
/// **二、切模式会连发两次检索**（竞态）
/// `setMode(perShot)` 自己猜了个第一镜（`_selectedShotIndex = 0`）并通知，
/// 紧接着调用方再把真正选中的那一镜纠正回来、又通知一次。两次通知各触发一次
/// 检索，而第一次那发是注定作废的。代次号只在真正发请求那一刻才自增，它前面
/// 还 `await` 着标签收窄的网络往返——所以作废的那一发完全可能先回来、先渲染。
void main() {
  group('选一次模式，候选面板只落地一次', () {
    testWidgets('注定作废的那一发不该打出去：选中 S2 点镜头替换，只检索 S2 的标签',
        (tester) async {
      final (editor, content, _) = await _pump(tester);

      // 用户是在时间线上点着 S2 才来选镜头级替换的
      editor.select(const EditorSelection.shot(0, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();

      expect(content.tagQueries, hasLength(1),
          reason: 'setMode 先猜了第一镜、随后被纠正成 S2，两次通知各打了一发。'
              '第一发注定作废，却已经占着网络、而且可能先回来先渲染');
      expect(content.tagQueries.single, unorderedEquals([_tagIds['中景']]),
          reason: '唯一该发出去的是 S2（中景）那一发');
    });

    testWidgets('标签那批既然不用，就一帧都不该露面', (tester) async {
      final (editor, content, seen) = await _pump(tester);

      editor.select(const EditorSelection.shot(0, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));

      // 逐帧走完，记录每一帧屏幕上出现过的「共 N 条」
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        seen.record(tester);
      }
      await tester.pumpAndSettle();
      seen.record(tester);

      expect(seen.totals, isNot(contains(_tagTotal)),
          reason: '按标签命中 $_tagTotal 条、宽到等于没筛，这批最终会被丢掉。'
              '它一旦被画出来，用户就可能在那几秒里点中一条跟这一镜毫无关系的素材');
      expect(seen.totals.last, _descTotal,
          reason: '最终落在画面描述那批上');
      expect(content.keywordQueries, hasLength(1),
          reason: '回退只该发生一次');
    });

    testWidgets('整体替换同理：选中 S2 之后点整段替换，也只该打一发',
        (tester) async {
      final (editor, content, _) = await _pump(tester);

      // 用户原话「无论是替换这个整段还是替换镜头」——两条路都要守
      editor.select(const EditorSelection.shot(0, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-mode-whole')));
      await tester.pumpAndSettle();

      expect(content.tagQueries, hasLength(1));
      expect(content.tagQueries.single, unorderedEquals([_unitTagId]),
          reason: '整体替换用这个台词语义单元自己的标签，不是镜头标签');
    });

    testWidgets('标签那批够用时，不该再多打一发画面描述', (tester) async {
      final (editor, content, _) =
          await _pump(tester, tagTotal: _usableTagTotal);

      editor.select(const EditorSelection.shot(0, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();

      expect(content.tagQueries, hasLength(1));
      expect(content.keywordQueries, isEmpty,
          reason: '标签结果一页就装得下，本来就该用它——不必再问一次语义搜');
    });
  });
}

// ---------------------------------------------------------------------------

/// 标签搜命中这么多：四页以上，前几十条等于随机取样，判定为不可用
const _tagTotal = 11265;

/// 画面描述语义搜命中这么多：这才是最终该落地的那批
const _descTotal = 554;

/// 一页就装得下，标签结果可用
const _usableTagTotal = 12;

const _tagIds = {'近景': 11, '中景': 12};

/// 台词语义单元层那一个标签（整体替换用它）
const _unitTagId = 21;

/// 屏幕上出现过哪些「共 N 条」——逐帧采样，用来证明中间态有没有露面
class _SeenTotals {
  final totals = <int>[];

  void record(WidgetTester tester) {
    final found = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .map(_parseTotal)
        .whereType<int>();
    for (final n in found) {
      if (totals.isEmpty || totals.last != n) totals.add(n);
    }
  }

  static int? _parseTotal(String s) {
    final m = RegExp(r'共 (\d+) 条').firstMatch(s);
    return m == null ? null : int.parse(m.group(1)!);
  }
}

class _FakeContentService implements MiaoaContentService {
  _FakeContentService({required this.tagTotal});

  final int tagTotal;
  final tagQueries = <List<int>>[];
  final keywordQueries = <String>[];

  @override
  Future<CandidatePage> searchByTags({
    required List<int> tagIds,
    String mode = 'or',
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    tagQueries.add(List.of(tagIds));
    // 标签收窄那一步要打网络，真机上它先走完、这一发才出去。
    // 这里给一个往返延迟，好让「作废的那一发先回来」这条竞态能被复现
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return CandidatePage(
      items: [_material(id: 9001, name: '标签宽结果')],
      total: tagTotal,
      skipped: 0,
    );
  }

  @override
  Future<CandidatePage> searchByDescription({
    required String keyword,
    List<int> tagIds = const [],
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    keywordQueries.add(keyword);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return CandidatePage(
      items: [_material(id: 9002, name: '语义搜结果')],
      total: _descTotal,
      skipped: 0,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CandidateMaterial _material({required int id, required String name}) =>
    CandidateMaterial(
      id: id,
      name: name,
      sceneDescription: name,
      thumbnailUrl: null,
      previewUrl: null,
      fileKey: null,
      tags: const [],
    );

class _FakeTagService implements MiaoaTagService {
  @override
  Future<List<TagInfo>> listTags(int groupId) async => groupId == 2
      ? const [TagInfo(id: _unitTagId, name: '主卖点解决方案')]
      : [for (final e in _tagIds.entries) TagInfo(id: e.value, name: e.key)];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 一个单元两个镜头，镜头标签各不相同——检索键能唯一指认是哪一镜。
/// 镜头带画面描述，回退到语义搜才有检索键
List<SemanticUnit> _units() => const [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '这个东西能把衣服洗干净',
        tags: ['主卖点解决方案'],
        shots: [
          Shot(startMs: 0, endMs: 1000, tags: ['近景'], description: '脏衣服特写'),
          Shot(
              startMs: 1000,
              endMs: 2000,
              tags: ['中景'],
              description: '女孩在书桌前情绪激动诉说'),
        ],
      ),
    ];

Future<(SegmentationEditorController, _FakeContentService, _SeenTotals)> _pump(
  WidgetTester tester, {
  int tagTotal = _tagTotal,
}) async {
  final editor = SegmentationEditorController(
    initialUnits: _units(),
    durationMs: 2000,
    fps: 30,
    sentences: const [],
  );
  final content = _FakeContentService(tagTotal: tagTotal);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 620,
        height: 900,
        child: CandidateTab(
          editor: editor,
          shotTagGroups: const [TagGroupRef(id: 1, name: '视觉镜头标签')],
          unitTagGroups: const [TagGroupRef(id: 2, name: '台词语义单元标签')],
          onReplacementsChanged: (_) {},
          contentService: content,
          tagService: _FakeTagService(),
          // 真机上规格探测约 3 秒/条，结果发布之后要过好几秒才轮到回退判定——
          // 那几秒正是用户能点中中间那批的窗口。假件必须把这个窗口留出来，
          // 否则整条链路在一个微任务里跑完，测试永远看不见中间态
          candidateProbe: CandidateProbe(run: (_, _) async {
            await Future<void>.delayed(const Duration(milliseconds: 80));
            throw 'no probe';
          }),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (editor, content, _SeenTotals());
}

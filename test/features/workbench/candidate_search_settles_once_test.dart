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

/// 候选面板**只能落地一次**，而且落的就是妙啊原样给的那一批。
///
/// 2026-09-18 真机，用户原话：「点了 U 的 S1，然后点替换这个镜头，无论是替换
/// 整段还是替换镜头，它这个镜头的搜索都会经过明显的两次跳转，然后才会跳转到
/// 真正的搜索结果上。第一次它会出现一些视频分镜，但是我不知道这些分镜是怎么
/// 来的……如果它慢的话，我接受它一个 Loading，但是我不接受它这样跳来跳去，
/// 因为中间我真的可能会选到那些。」
///
/// 2026-09-20 他又指出：改完之后**匹配的结果都不对了**，并定死了检索该怎么写：
/// 「搜索的逻辑不应该有任何的处理，它就是在妙啊的上面拿到搜索结果就好了。
/// 我们唯一控制的是条件……筛选条件当我选的是标签的时候，你就把对应的这个
/// 参考视频的标签放进去就好了。它是什么结果展示出来，你就展示什么结果。
/// 至于对于结果进行二次的判断，然后去掉一些不符合要求的结果，这些不要。」
///
/// 所以这一组守三条：
///
/// **一、条件原样传**：这一镜有几个标签就传几个，一个都不许剔。
/// 曾经会把「命中得太宽」的标签从检索键里拿掉——用户选的条件被改掉了，
/// 而界面上仍显示他自己那几个标签，结果对不上就无从查起。
///
/// **二、结果原样收**：命中一万多条也照样用这一批，不许自动改走画面描述。
/// 换检索方式是判断，不是软件该替人做的事。
///
/// **三、只跳一次**：连发两次检索的另一条成因是切模式——
/// `setMode(perShot)` 自己猜了个第一镜（`_selectedShotIndex = 0`）并通知，
/// 紧接着调用方再把真正选中的那一镜纠正回来、又通知一次。
/// 两次通知各触发一次检索，而第一次那发是注定作废的。
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

    testWidgets('命中再宽也用这一批，不许偷偷改走画面描述', (tester) async {
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

      expect(content.keywordQueries, isEmpty,
          reason: '用户选的是标签检索。命中 $_tagTotal 条宽不宽是他自己判断的事，'
              '软件不许因为嫌宽就换一套结果给他——换了他还以为自己在按标签搜');
      expect(seen.totals, [_tagTotal],
          reason: '整个过程只出现过一个「共 N 条」：标签那一批。'
              '出现两个就说明中间那批露过面，而他真的会在那几秒里点中');
    });

    testWidgets('这一镜有几个标签就传几个，一个都不许剔', (tester) async {
      final (editor, content, _) = await _pump(tester, shotTags: ['近景', '实拍']);

      editor.select(const EditorSelection.shot(0, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
      await tester.pumpAndSettle();

      expect(content.tagQueries, hasLength(1));
      expect(content.tagQueries.single,
          unorderedEquals([_tagIds['近景'], _tagIds['实拍']]),
          reason: '「实拍」命中得再宽也是用户选的条件。'
              '曾经会把它剔掉，于是界面显示的标签和真正搜的标签对不上');
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
  });
}

// ---------------------------------------------------------------------------

/// 标签搜命中这么多。真机上 35 个镜头每一镜都是这个数——宽得离谱，
/// 但宽不宽由用户自己判断，软件照搜照显示
const _tagTotal = 11265;

/// 画面描述语义搜命中这么多。这一批**不该出现**：没人点过画面描述
const _descTotal = 554;

const _tagIds = {'近景': 11, '中景': 12, '实拍': 13};

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
    // 给一个往返延迟，好让「作废的那一发先回来、先渲染」这条竞态能被复现
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
/// 镜头带画面描述：真有人去点画面描述检索时才有检索键，
/// 也让「软件自己偷偷换过去」这件事能被抓住
List<SemanticUnit> _units(List<String> firstShotTags) => [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '这个东西能把衣服洗干净',
        tags: const ['主卖点解决方案'],
        shots: [
          Shot(
              startMs: 0,
              endMs: 1000,
              tags: firstShotTags,
              description: '脏衣服特写'),
          const Shot(
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
  List<String> shotTags = const ['近景'],
}) async {
  final editor = SegmentationEditorController(
    initialUnits: _units(shotTags),
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

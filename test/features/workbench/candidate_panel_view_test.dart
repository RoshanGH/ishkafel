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

/// 每页 3 条、共 7 条：够验证翻页，又不必造一屏数据
class _Content implements MiaoaContentService {
  final pages = <int>[];

  /// 置 true 后检索一律返回 0 条（用来看空结果的引导）
  bool empty = false;

  /// 逐个标签数条数时收到的调用
  final singleTagCalls = <int>[];

  CandidatePage _page(int page, int pageSize) {
    final all = List.generate(
      7,
      (i) => CandidateMaterial(
        id: 100 + i,
        name: '素材$i',
        sceneDescription: '画面描述$i',
        voiceover: i == 6 ? '' : '这是第 $i 条素材的台词',
        thumbnailUrl: null,
        previewUrl: 'https://cdn/$i.mp4',
        fileKey: null,
        // 只有第 2 条带着检索标签——素材库按「任一命中」返回，
        // 顺序大致是入库时间倒序
        tags: i == 2 ? const ['促单'] : const [],
      ),
    );
    final from = (page - 1) * pageSize;
    return CandidatePage(
      items: all.skip(from).take(pageSize).toList(),
      total: all.length,
      skipped: 0,
    );
  }

  @override
  Future<CandidatePage> searchByTags({
    required List<int> tagIds,
    String mode = 'or',
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    // pageSize 1 = 逐个标签数条数，不是正经检索
    if (pageSize == 1) {
      singleTagCalls.add(tagIds.single);
      return CandidatePage(
          items: const [], total: tagIds.single == 21 ? 0 : 4, skipped: 0);
    }
    pages.add(page);
    if (empty) {
      return CandidatePage(items: const [], total: 0, skipped: 0);
    }
    return _page(page, pageSize);
  }

  @override
  Future<CandidatePage> searchByDescription({
    required String keyword,
    List<int> projectIds = const [],
    int page = 1,
    int pageSize = 20,
  }) async {
    pages.add(page);
    return _page(page, pageSize);
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tags implements MiaoaTagService {
  @override
  Future<List<TagInfo>> listTags(int groupId) async => switch (groupId) {
        1 => const [TagInfo(id: 11, name: '近景')],
        2 => const [TagInfo(id: 21, name: '促单')],
        _ => const [],
      };

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: '第一句台词',
        tags: ['促单'],
        shots: [
          Shot(startMs: 0, endMs: 2000, tags: ['近景'], description: '手持产品'),
          Shot(startMs: 2000, endMs: 4000, tags: ['近景'], description: '擦台面'),
        ],
      ),
    ];

late List<CandidateMaterial> played;

Future<_Content> _pump(WidgetTester tester, {bool empty = false}) async {
  played = [];
  final content = _Content()..empty = empty;
  tester.view.physicalSize = const Size(360, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 340,
        height: 880,
        child: CandidateTab(
          editor: SegmentationEditorController(
            initialUnits: _units(),
            durationMs: 4000,
            fps: 30,
            sentences: const [],
          ),
          shotTagGroups: const [TagGroupRef(id: 1, name: '画面层')],
          unitTagGroups: const [TagGroupRef(id: 2, name: '台词层')],
          onReplacementsChanged: (_) {},
          contentService: content,
          tagService: _Tags(),
          candidateProbe: CandidateProbe(run: (_, _) async => throw 'no probe'),
          onPreview: (context, material) async => played.add(material),
          // 每页 3 条：够验证翻页，又不必造一屏数据
          pageSize: 3,
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return content;
}

Future<void> _whole(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('picking-mode-whole')));
  await tester.pumpAndSettle();
}

Future<void> _perShot(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('picking-mode-per-shot')));
  await tester.pumpAndSettle();
}

void main() {
  group('整体替换优先看台词', () {
    testWidgets('默认就是台词列表，能直接读到候选素材说了什么', (tester) async {
      await _pump(tester);
      await _whole(tester);

      expect(find.text('这是第 0 条素材的台词'), findsOneWidget,
          reason: '换的是「一句台词对应的一段画面」，'
              '只给缩略图用户得一条条点开听');
    });

    testWidgets('没有台词的素材退回画面描述，不留一片空白', (tester) async {
      await _pump(tester);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-next-page')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-next-page')));
      await tester.pumpAndSettle();

      expect(find.text('画面描述6'), findsOneWidget);
    });

    testWidgets('能切到画面视图', (tester) async {
      await _pump(tester);
      await _whole(tester);

      await tester.tap(find.byKey(const Key('picking-view-gallery')));
      await tester.pumpAndSettle();

      expect(find.text('这是第 0 条素材的台词'), findsNothing);
      expect(find.byKey(const Key('picking-candidate-100')), findsOneWidget);
    });
  });

  group('镜头替换只看画面', () {
    testWidgets('没有台词/画面两个视图按钮——那一层挑的就是画面', (tester) async {
      await _pump(tester);
      await _perShot(tester);

      expect(find.byKey(const Key('picking-view-transcript')), findsNothing);
      expect(find.byKey(const Key('picking-candidate-100')), findsOneWidget);
    });
  });

  group('试看', () {
    testWidgets('台词列表里能试看', (tester) async {
      await _pump(tester);
      await _whole(tester);

      await tester.tap(find.byKey(const Key('picking-play-100')));
      await tester.pumpAndSettle();

      expect(played.single.id, 100,
          reason: '静止的一帧几乎分不出差别，而替换进成片的是这段画面在动的三秒');
    });

    testWidgets('画面网格里也能试看', (tester) async {
      await _pump(tester);
      await _perShot(tester);

      await tester.tap(find.byKey(const Key('picking-play-100')));
      await tester.pumpAndSettle();

      expect(played.single.id, 100);
    });
  });

  group('分页', () {
    testWidgets('写明第几页、共几条——命中几百条只给第一页，用户不知道后面还有',
        (tester) async {
      await _pump(tester);
      await _whole(tester);

      expect(find.textContaining('共 7 条'), findsOneWidget);
      expect(find.textContaining('第 1/'), findsOneWidget);
    });

    testWidgets('翻到下一页拿的是下一页的数据', (tester) async {
      final content = await _pump(tester);
      await _whole(tester);

      await tester.tap(find.byKey(const Key('picking-next-page')));
      await tester.pumpAndSettle();

      expect(content.pages.last, 2);
      expect(find.textContaining('第 2/'), findsOneWidget);
    });

    testWidgets('换检索键回到第 1 页——停在第 3 页会看到一片空白', (tester) async {
      final content = await _pump(tester);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-next-page')));
      await tester.pumpAndSettle();

      await _perShot(tester);

      expect(content.pages.last, 1);
    });
  });

  group('命中的标签要标出来', () {
    testWidgets('写明命中了哪几个标签', (tester) async {
      await _pump(tester);
      await _whole(tester);

      final rows = tester
          .widgetList<Text>(find.descendant(
            of: find.byKey(const Key('picking-candidate-102')),
            matching: find.byType(Text),
          ))
          .map((t) => t.data)
          .toList();

      expect(rows, contains('1/1'));
      expect(rows, contains('促单'),
          reason: '只说「命中 1 个」判断不了像不像——命中的是哪个标签才是关键');
    });

    testWidgets('顺序就是素材库给的顺序，不做客户端重排', (tester) async {
      await _pump(tester);
      await _whole(tester);

      // 100、101、102 按素材库返回的先后排；102 命中标签也不会被提前
      final a = tester.getTopLeft(find.byKey(const Key('picking-candidate-100')));
      final c = tester.getTopLeft(find.byKey(const Key('picking-candidate-102')));

      expect(a.dy, lessThan(c.dy),
          reason: '只排当前这一页毫无意义：实测 5437 条结果的第一页里'
              '重合度全是 1，排了跟没排一样，却给人「已按相似度排过」的错觉');
    });
  });

  group('搜不到时说清楚是哪个标签没有', () {
    testWidgets('点一下就把每个标签各有多少条摊开', (tester) async {
      final content = await _pump(tester, empty: true);
      await _whole(tester);

      await tester.tap(find.byKey(const Key('picking-probe-tag-hits')));
      await tester.pumpAndSettle();

      expect(content.singleTagCalls, [21],
          reason: '这一层只有「促单」一个标签');
      expect(find.byKey(const Key('picking-tag-hit-21')), findsOneWidget);
      expect(find.text('0 条'), findsOneWidget,
          reason: '用户要判断的是「我标签打错了，还是库里这一类没入库」');
    });

    testWidgets('不点就不去数——每个标签一次子进程', (tester) async {
      final content = await _pump(tester, empty: true);
      await _whole(tester);

      expect(content.singleTagCalls, isEmpty);
      expect(find.byKey(const Key('picking-probe-tag-hits')), findsOneWidget);
    });

    testWidgets('有结果时不摆这个按钮', (tester) async {
      await _pump(tester);
      await _whole(tester);

      expect(find.byKey(const Key('picking-probe-tag-hits')), findsNothing);
    });
  });
}

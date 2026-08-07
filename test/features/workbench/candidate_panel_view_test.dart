import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/project_ref.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'dart:io';

import 'package:ishkafel/core/replacement/picked_material.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/picking/picked_media_cache.dart';
import 'package:ishkafel/features/picking/candidate_row.dart';
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

/// 标签表拉得很慢：用来复现「表还没到手就检索」
class _SlowTags implements MiaoaTagService {
  final Completer<void> gate;
  _SlowTags(this.gate);

  @override
  Future<List<TagInfo>> listTags(int groupId) async {
    await gate.future;
    return switch (groupId) {
      1 => const [TagInfo(id: 11, name: '近景')],
      2 => const [TagInfo(id: 21, name: '促单')],
      _ => const [],
    };
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

Future<_Content> _pump(WidgetTester tester,
    {bool empty = false,
    ProjectRef? project,
    PickedMediaCache? cache,
    List<UnitReplacement>? initial}) async {
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
          project: project,
          mediaCache: cache,
          initialReplacements: initial,
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

  group('项目组范围一直摆在明面上', () {
    /// 项目组是排他性的筛选条件。看不见它，用户就没法判断
    /// 「搜出来的东西不对」是标签选错了还是根本没限项目——
    /// 真实排查里就为这个来回猜过一轮。
    testWidgets('设了项目组就写出是哪个', (tester) async {
      await _pump(tester,
          project: const ProjectRef(id: 104, name: '滴露植源喷雾'));

      expect(find.text('限定项目组 · 滴露植源喷雾'), findsOneWidget);
    });

    testWidgets('没设项目组时明确说搜的是全部项目', (tester) async {
      await _pump(tester);

      expect(find.text('未设项目组 · 搜的是我的全部项目'), findsOneWidget);
    });

    testWidgets('换到镜头替换照样在——两层用的是同一个项目组', (tester) async {
      await _pump(tester,
          project: const ProjectRef(id: 104, name: '滴露植源喷雾'));
      await _perShot(tester);

      expect(find.text('限定项目组 · 滴露植源喷雾'), findsOneWidget);
    });
  });

  group('标签表还没到手时不能报「未选择任何标签」', () {
    /// 标签表是异步拉的。第一次进面板时它还没到手，这一刻算出的检索键是
    /// 空的——此前会照样把空检索键发给 CLI，换回一句红色的「未选择任何
    /// 标签，无法检索候选素材」；更糟的是拉完之后检索指纹没变，不会重跑，
    /// 面板就一直卡在那句红字上，只能退出任务再进来。
    testWidgets('标签表拉回来之后自动重搜，不停在「无法检索」上', (tester) async {
      final gate = Completer<void>();
      final content = _Content();
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
              tagService: _SlowTags(gate),
              candidateProbe:
                  CandidateProbe(run: (_, _) async => throw 'no probe'),
              onPreview: (context, material) async {},
              pageSize: 3,
            ),
          ),
        ),
      ));
      await tester.pump();
      await _whole(tester);

      expect(content.pages, isEmpty,
          reason: '标签还没解析出来就调 CLI，只会换回一句红字');

      gate.complete();
      await tester.pumpAndSettle();

      expect(content.pages, isNotEmpty, reason: '表到手了就该自己重搜');
      expect(find.text('这是第 0 条素材的台词'), findsOneWidget);
    });
  });

  group('一屏能看到几条', () {
    /// 用户原话：「我草，好烦，就看两条吗？」——右栏宽 1200 而高只有 400 出头，
    /// 单列 88pt 的行一屏只放得下两条，右边一半宽度全空着。
    testWidgets('面板够宽时台词行分成多列铺开', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1360,
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
              contentService: _Content(),
              tagService: _Tags(),
              candidateProbe:
                  CandidateProbe(run: (_, _) async => throw 'no probe'),
              onPreview: (context, material) async {},
              pageSize: 3,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await _whole(tester);

      final rows = tester
          .widgetList<CandidateRow>(find.byType(CandidateRow))
          .toList();
      expect(rows.length, greaterThan(1));
      final first = tester.getTopLeft(find.byWidget(rows[0]));
      final second = tester.getTopLeft(find.byWidget(rows[1]));
      expect(second.dy, first.dy,
          reason: '1360 宽应该排得下两列，第二条要和第一条同一行');
      expect(second.dx, greaterThan(first.dx));
    });
  });

  group('已选托盘：我选了哪几条，一直看得见', () {
    /// 勾选状态原本只画在候选卡上，而候选卡只有当前这一页的检索结果。
    /// 翻页/换检索方式/换项目组之后一个勾都看不见——用户原话
    /// 「我没有看到我选了那 3 个，我不知道是不是我那 3 个」。
    testWidgets('勾上就出现在托盘里', (tester) async {
      await _pump(tester);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('picked-chip-100')), findsOneWidget);
      expect(find.text('已选 1 条'), findsOneWidget);
    });

    testWidgets('翻到下一页也还在——它和这一页搜到什么无关', (tester) async {
      await _pump(tester);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-next-page')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('picking-candidate-100')), findsNothing,
          reason: '第 2 页没有这条素材');
      expect(find.byKey(const Key('picked-chip-100')), findsOneWidget,
          reason: '但我选了它，就得一直看得见');
    });

    testWidgets('托盘上能直接取消勾选', (tester) async {
      await _pump(tester);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picked-remove-100')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('picked-chip-100')), findsNothing);
    });

    testWidgets('镜头替换那一层同样有托盘——两层是同一套问题', (tester) async {
      await _pump(tester);
      await _perShot(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('picked-chip-100')), findsOneWidget);
    });

    testWidgets('换到另一个镜头时托盘跟着换——托盘是当前作用域的', (tester) async {
      await _pump(tester);
      await _perShot(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-shot-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('picked-chip-100')), findsNothing,
          reason: 'S1 选的那条不该算在 S2 头上');
    });

    testWidgets('落地记录上抛给工作台存盘', (tester) async {
      final saved = <List<PickedMaterial>>[];
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
              onPickedMaterialsChanged: saved.add,
              contentService: _Content(),
              tagService: _Tags(),
              candidateProbe:
                  CandidateProbe(run: (_, _) async => throw 'no probe'),
              onPreview: (context, material) async {},
              pageSize: 3,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      expect(saved.last.single.id, 100);
      expect(saved.last.single.voiceover, '这是第 0 条素材的台词',
          reason: '存的是「这条素材是什么」，不只是一个 id');

      // 取消勾选之后记录也要清掉，不留垃圾
      await tester.tap(find.byKey(const Key('picked-remove-100')));
      await tester.pumpAndSettle();
      expect(saved.last, isEmpty);
    });
  });

  group('已选素材要固定在本地', () {
    /// 用户的担心：「万一我在执行导出的时候，其他人在妙啊的系统上执行把
    /// 这些素材删掉，我就很尴尬了」。所以挑中就把本体拉到本地。
    testWidgets('打开一条早就选好的任务，进来就开始固定', (tester) async {
      final asked = <int>[];
      final cache = PickedMediaCache(
        fetch: (id) async {
          asked.add(id);
          return '/local/$id.mp4';
        },
        cacheDir: Directory.systemTemp.createTempSync('ishkafel_tab_'),
      );
      addTearDown(cache.dispose);

      await _pump(tester,
          cache: cache,
          initial: [UnitReplacement.whole(const [100])]);

      expect(asked, [100],
          reason: '只在勾选变化时才固定的话，打开一条早就选好的任务什么都不会发生'
              '——而那正是最需要提前把素材抓在手里的时候');
    });

    testWidgets('取消勾选只解除固定，不重新下载', (tester) async {
      final asked = <int>[];
      final cache = PickedMediaCache(
        fetch: (id) async {
          asked.add(id);
          return '/local/$id.mp4';
        },
        cacheDir: Directory.systemTemp.createTempSync('ishkafel_tab2_'),
      );
      addTearDown(cache.dispose);

      await _pump(tester, cache: cache);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picked-remove-100')));
      await tester.pumpAndSettle();

      expect(cache.pinned, isEmpty);
      expect(asked, [100], reason: '取消不该触发第二次下载');
    });
  });

  group('已选的那几条在下面的结果列表里怎么呈现', () {
    /// 托盘是「我选了什么」，结果列表是「库里有什么」——两处呈现的是同一份
    /// 勾选数据，任一处操作都同步。不从结果里剔掉已选的：剔了之后条目会
    /// 跳位，而且用户想取消时反而在列表里找不到它。
    testWidgets('照样出现在结果列表里，而且是选中态', (tester) async {
      await _pump(tester);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      // Key 挂在 CandidateRow 内部的 GestureDetector 上，所以按 entry 找
      final row = tester
          .widgetList<CandidateRow>(find.byType(CandidateRow))
          .firstWhere((r) => r.entry.material.id == 100);
      expect(row.selected, isTrue, reason: '选了就得画成选中，否则用户会以为没生效');
      expect(row.isPreview, isTrue, reason: '第一条选中的默认就是预览版');
    });

    testWidgets('结果列表的条数与顺序不因为选了什么而变', (tester) async {
      await _pump(tester);
      await _whole(tester);
      final before = tester
          .widgetList<CandidateRow>(find.byType(CandidateRow))
          .map((r) => r.entry.material.id)
          .toList();

      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      final after = tester
          .widgetList<CandidateRow>(find.byType(CandidateRow))
          .map((r) => r.entry.material.id)
          .toList();
      expect(after, before, reason: '顺序就是素材库给的顺序，选中不参与重排');
    });

    testWidgets('在列表里再点一下就取消，托盘同步消失', (tester) async {
      await _pump(tester);
      await _whole(tester);
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picking-candidate-100')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('picked-chip-100')), findsNothing);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/models/video_info.dart';
import 'package:ishkafel/features/workbench/workbench_chrome.dart';
import 'package:ishkafel/features/workbench/workbench_summary.dart';

RenewTask _task({TagGroupRef? unitGroup, TagGroupRef? shotGroup}) => RenewTask(
      id: 't1',
      name: '滴露_自然消毒液',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 7, 30),
      updatedAt: DateTime.utc(2026, 7, 30),
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(seconds: 75),
          fps: 30,
          fileSizeBytes: 1),
      unitTagGroups: unitGroup == null ? const [] : [unitGroup],
      shotTagGroups: shotGroup == null ? const [] : [shotGroup],
    );

List<SemanticUnit> _units({
  List<String> unitTags = const [],
  List<String> shotTags = const [],
}) =>
    [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句',
        tags: unitTags,
        shots: [Shot(startMs: 0, endMs: 2000, tags: shotTags)],
      ),
      const SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句',
        shots: [Shot(startMs: 2000, endMs: 4000)],
      ),
    ];

/// 两层都打满标签
List<SemanticUnit> _allTagged() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: '第一句',
        tags: ['功效演示'],
        shots: [Shot(startMs: 0, endMs: 2000, tags: ['产品特写'])],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 4000,
        transcript: '第二句',
        tags: ['促销'],
        shots: [Shot(startMs: 2000, endMs: 4000, tags: ['近景'])],
      ),
    ];

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  _composedDuration();
  group('顶栏第二行显示两个标签组（设计稿：标签组 衣清.消毒液 / 画面类型）', () {
    testWidgets('两个标签组都选了时按「单元组 / 镜头组」显示名字而不是 id',
        (tester) async {
      await _pump(
        tester,
        WorkbenchTopBar(
          task: _task(
            unitGroup: const TagGroupRef(id: 1279, name: '衣清.消毒液'),
            shotGroup: const TagGroupRef(id: 136, name: '画面类型'),
          ),
          onBack: () {},
        ),
      );

      expect(find.textContaining('标签组'), findsOneWidget);
      expect(find.textContaining('衣清.消毒液'), findsOneWidget);
      expect(find.textContaining('画面类型'), findsOneWidget);
      expect(find.textContaining('1279'), findsNothing, reason: 'id 是技术黑话');
    });

    testWidgets('没有标签组时明说「不会打标」，而不是什么都不显示',
        (tester) async {
      await _pump(tester, WorkbenchTopBar(task: _task(), onBack: () {}));

      expect(find.textContaining('未设置标签组'), findsOneWidget,
          reason: '什么都不显示，用户只会以为这条任务本来就不用标签，'
              '而实际上打标和标签检索都被悄悄跳过了');
    });

    testWidgets('有「标签组」入口可以点开去改', (tester) async {
      await _pump(tester,
          WorkbenchTopBar(task: _task(), onBack: () {}, onEditTagGroups: () {}));

      expect(find.byKey(const Key('workbench-tag-groups-btn')), findsOneWidget,
          reason: '标签组只在新建向导里选一次、选漏了再也改不了的话，'
              '那条任务从此打不出标签');
    });
  });

  group('底部摘要补两层打标情况', () {
    test('两层都打满了才叫「打标完成」', () {
      final text = workbenchSummaryText(
        units: _allTagged(),
        durationMs: 96200,
        dirty: false,
        hasTagGroups: true,
      );

      expect(text, contains('两层打标完成'));
      expect(text, contains('单元 2/2'));
      expect(text, contains('镜头 2/2'));
    });

    test('镜头一个都没打时不能写「打标完成」', () {
      final text = workbenchSummaryText(
        units: _units(unitTags: const ['功效演示']),
        durationMs: 96200,
        dirty: false,
        hasTagGroups: true,
      );

      expect(text, isNot(contains('完成')),
          reason: '真机上出现过「两层打标完成（单元 6/6 · 镜头 0/52）」——'
              '括号里明明白白写着一个都没打，前面却说完成了');
      expect(text, contains('镜头 0/2'));
    });

    test('部分打上（打标中途失败）时如实说覆盖了多少', () {
      final text = workbenchSummaryText(
        units: _units(unitTags: const ['功效演示'], shotTags: const ['产品特写']),
        durationMs: 96200,
        dirty: false,
        hasTagGroups: true,
      );

      expect(text, contains('单元 1/2'));
      expect(text, contains('镜头 1/2'));
      expect(text, isNot(contains('完成')));
    });

    test('选了标签组却一个标签都没有时如实说明，而不是假装打标完成', () {
      final text = workbenchSummaryText(
        units: _units(),
        durationMs: 96200,
        dirty: false,
        hasTagGroups: true,
      );

      expect(text, contains('未获得标签'));
      expect(text, isNot(contains('两层打标完成')));
    });

    test('旧任务（没选标签组）不提打标，摘要保持原样', () {
      final text = workbenchSummaryText(
        units: _units(),
        durationMs: 96200,
        dirty: false,
        hasTagGroups: false,
      );

      expect(text, '共 2 个台词语义单元 · 2 个视觉镜头 · 时长 96.2s');
    });

    test('改过之后不再谎称「有未保存的修改」——改动是随手落库的', () {
      final text = workbenchSummaryText(
        units: _units(),
        durationMs: 96200,
        dirty: true,
        hasTagGroups: false,
      );

      expect(text, isNot(contains('未保存')),
          reason: '工作台里每次改动都直接落库，还挂着「有未保存的修改」'
              '只会让用户去找一个不存在的保存按钮');
      expect(text, contains('已自动保存'));
    });
  });
}

/// 时间线画的已经是成片了，底部这一行也得跟上
void _composedDuration() {
  List<SemanticUnit> units() => const [
        SemanticUnit(
            index: 0, startMs: 0, endMs: 15090, transcript: 'U1', shots: []),
      ];

  String summary({int? composedMs}) => workbenchSummaryText(
        units: units(),
        durationMs: 96200,
        dirty: false,
        hasTagGroups: false,
        composedMs: composedMs,
      );

  group('成片时长与原片时长', () {
    test('替换让长度变了就两个都写出来——只报原片会让人以为哪儿算错了', () {
      final text = summary(composedMs: 92460);

      expect(text, contains('时长 92.5s'));
      expect(text, contains('原片 96.2s'));
    });

    test('没变时只写一个，不制造多余信息', () {
      expect(summary(composedMs: 96200), contains('时长 96.2s'));
      expect(summary(composedMs: 96200), isNot(contains('原片')));
    });

    test('差得极小（不到 0.1 秒）也当没变——转码的零头不该显示成两个数', () {
      expect(summary(composedMs: 96250), isNot(contains('原片')));
    });

    test('还没算出成片时长时按原片报，不留空', () {
      expect(summary(), contains('时长 96.2s'));
    });
  });
}

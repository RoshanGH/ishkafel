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
      status: RenewTaskStatus.awaitingCut,
      createdAt: DateTime.utc(2026, 7, 30),
      updatedAt: DateTime.utc(2026, 7, 30),
      videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(seconds: 75),
          fps: 30,
          fileSizeBytes: 1),
      unitTagGroup: unitGroup,
      shotTagGroup: shotGroup,
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

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
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

    testWidgets('旧任务没有标签组时不显示这一行（不留空标题）', (tester) async {
      await _pump(tester, WorkbenchTopBar(task: _task(), onBack: () {}));

      expect(find.textContaining('标签组'), findsNothing);
    });
  });

  group('底部摘要补两层打标情况', () {
    test('有标签时给出两层的打标覆盖情况', () {
      final text = workbenchSummaryText(
        units: _units(unitTags: const ['功效演示'], shotTags: const ['产品特写']),
        durationMs: 96200,
        dirty: false,
        hasTagGroups: true,
      );

      expect(text, contains('两层打标完成'));
      expect(text, contains('单元 1/2'));
      expect(text, contains('镜头 1/2'));
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

    test('有未保存修改时仍然带上提示', () {
      final text = workbenchSummaryText(
        units: _units(),
        durationMs: 96200,
        dirty: true,
        hasTagGroups: false,
      );

      expect(text, endsWith('有未保存的修改'));
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';
import 'package:ishkafel/features/workbench/workbench_chrome.dart';

SegmentationEditorController _controller({EditorSelection? selection}) {
  final c = SegmentationEditorController(
    initialUnits: const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: '第一句台词',
        shots: [Shot(startMs: 0, endMs: 2000), Shot(startMs: 2000, endMs: 4000)],
      ),
    ],
    durationMs: 4000,
    fps: 30,
    sentences: const [],
  );
  if (selection != null) c.select(selection);
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  group('UI 文案遵循术语表统一话术（docs/术语表.md）', () {
    testWidgets('选中单元时用全称「台词语义单元」', (tester) async {
      await _pump(
        tester,
        InspectorPanel(
          controller: _controller(selection: const EditorSelection.unit(0)),
          fps: 30,
        ),
      );

      expect(find.textContaining('台词语义单元'), findsWidgets,
          reason: '术语表的标准词是「台词语义单元」，「单元详情」是内部简称');
      expect(find.textContaining('单元详情'), findsNothing);
    });

    testWidgets('选中镜头时用全称「视觉镜头」', (tester) async {
      await _pump(
        tester,
        InspectorPanel(
          controller: _controller(selection: const EditorSelection.shot(0, 1)),
          fps: 30,
        ),
      );

      expect(find.textContaining('视觉镜头'), findsWidgets);
      expect(find.textContaining('镜头详情'), findsNothing);
    });

    testWidgets('拆分按钮说清拆的是哪一层，两层不再共用一句话', (tester) async {
      await _pump(
        tester,
        InspectorPanel(
          controller: _controller(selection: const EditorSelection.unit(0)),
          fps: 30,
        ),
      );
      expect(find.textContaining('拆分单元'), findsOneWidget,
          reason: '两层共用「在游标处拆分」会让用户不确定拆的是哪一层');

      await _pump(
        tester,
        InspectorPanel(
          controller: _controller(selection: const EditorSelection.shot(0, 1)),
          fps: 30,
        ),
      );
      expect(find.textContaining('拆分镜头'), findsOneWidget);
    });
  });

  group('底部栏只剩「当前事实」与「下一步出口」', () {
    testWidgets('摘要文案用术语表全称', (tester) async {
      await _pump(
        tester,
        const WorkbenchBottomBar(
          summaryText: '共 3 个台词语义单元 · 12 个视觉镜头 · 时长 96.2s',
        ),
      );

      expect(find.textContaining('台词语义单元'), findsOneWidget);
      expect(find.textContaining('视觉镜头'), findsOneWidget);
    });

    testWidgets('不再有「确认切分」——切分与选材在同一个工作台里交替进行',
        (tester) async {
      await _pump(
        tester,
        const WorkbenchBottomBar(summaryText: '共 3 个台词语义单元'),
      );

      expect(find.textContaining('确认切分'), findsNothing,
          reason: '这道闸门把两件本来交替进行的事硬拆成两个阶段：'
              '挑着素材发现这刀切得不对，该直接在时间线上拖一下');
      expect(find.byKey(const Key('workbench-export-btn')), findsOneWidget);
    });

    testWidgets('不能导出时按钮禁用，并把原因写出来', (tester) async {
      await _pump(
        tester,
        const WorkbenchBottomBar(
          summaryText: '共 3 个台词语义单元',
          blockedReason: '当前组合 128 条，超过上限 100，请减少 U2 的候选',
        ),
      );

      final btn = tester.widget<FilledButton>(
          find.byKey(const Key('workbench-export-btn')));
      expect(btn.onPressed, isNull);
      expect(find.textContaining('超过上限'), findsOneWidget,
          reason: '点不动又不说为什么，用户只会反复点它并怀疑软件坏了');
    });

    testWidgets('可以导出时显示组合数', (tester) async {
      await _pump(
        tester,
        WorkbenchBottomBar(
          summaryText: '共 3 个台词语义单元',
          combinationText: '当前组合 2 × 3 = 6 条',
          onExport: () {},
        ),
      );

      expect(find.textContaining('6 条'), findsOneWidget);
    });
  });
}

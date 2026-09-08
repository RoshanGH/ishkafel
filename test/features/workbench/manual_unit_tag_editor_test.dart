import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/features/workbench/inspector_panel.dart';

/// 手加的台词语义单元**必须能手填标签**。
///
/// 它没有台词——原片里没有它，ASR 也就无从转写。没有台词，模型就没有任何
/// 东西可以据以打标；而标签正是去妙啊搜画面的检索键。不给手填的话，这个
/// 单元永远搜不出素材，加了也只是个一直挂着「待填」的空壳。
///
/// 反过来，分析切出来的单元不该在这里手改：那边的标签是模型按台词打的，
/// 手改会和「重新打标」互相覆盖，而用户看不出是谁赢了。
void main() {
  SemanticUnit unit({required bool hasSource}) => SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 5000,
        transcript: hasSource ? '这是原片的台词' : '',
        hasSource: hasSource,
      );

  Future<void> pump(WidgetTester tester, SemanticUnit u) async {
    final controller = SegmentationEditorController(
      initialUnits: [u],
      durationMs: 5000,
      fps: 30,
      sentences: const [],
    );
    controller.select(EditorSelection.unit(0));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InspectorPanel(
          controller: controller,
          fps: 30,
          unitTagEditor: (i, u) => u.hasSource
              ? null
              : const Text('手填标签', key: ValueKey('manual-tags')),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('手加的单元：给手填标签的编辑器', (tester) async {
    await pump(tester, unit(hasSource: false));

    expect(find.byKey(const ValueKey('manual-tags')), findsOneWidget);
  });

  testWidgets('分析切出来的单元：不给手填，摆的是模型打标的结果', (tester) async {
    await pump(tester, unit(hasSource: true));

    expect(find.byKey(const ValueKey('manual-tags')), findsNothing);
    expect(find.text('台词语义单元标签'), findsOneWidget);
  });

  testWidgets('手加的单元没有台词：不摆台词框、也不给拆分/并入', (tester) async {
    await pump(tester, unit(hasSource: false));

    expect(find.textContaining('单元台词'), findsNothing,
        reason: '它没有台词，摆一个永远空的框只会让人以为哪儿坏了');
    expect(find.textContaining('拆分单元'), findsNothing,
        reason: '没有台词可拆，也没有原片区间可并');
  });

  testWidgets('分析切出来的单元照旧有台词框和拆分', (tester) async {
    await pump(tester, unit(hasSource: true));

    expect(find.textContaining('单元台词'), findsOneWidget);
    expect(find.textContaining('拆分单元'), findsOneWidget);
  });
}

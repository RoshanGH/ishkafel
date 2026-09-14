import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/workbench/base_segment_card.dart';

SemanticUnit _inserted({int? pinned, List<Shot> shots = const []}) =>
    SemanticUnit(
      uid: 'u1',
      index: 1,
      startMs: 4000,
      endMs: 10000,
      transcript: '',
      hasSource: false,
      baseCandidateId: pinned,
      shots: shots,
    );

SemanticUnit _fromSource() => const SemanticUnit(
      uid: 'u0',
      index: 0,
      startMs: 0,
      endMs: 4000,
      transcript: '第一句',
      shots: [Shot(startMs: 0, endMs: 4000)],
    );

Future<void> _pump(
  WidgetTester tester, {
  required SemanticUnit unit,
  required UnitReplacement replacement,
  String? materialName,
  bool segmenting = false,
  bool retagging = false,
  VoidCallback? onSegment,
  VoidCallback? onUnpin,
  VoidCallback? onRetag,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: BaseSegmentCard(
            unit: unit,
            replacement: replacement,
            materialName: materialName,
            segmenting: segmenting,
            retagging: retagging,
            onSegment: onSegment,
            onUnpin: onUnpin,
            onRetag: onRetag,
          ),
        ),
      ),
    ));

void main() {
  testWidgets('底片是原片的段落不摆这张卡——只说「用的是原片」是噪音',
      (tester) async {
    await _pump(tester,
        unit: _fromSource(), replacement: UnitReplacement.keepOriginal());

    expect(find.byKey(const Key('base-segment-card')), findsNothing);
  });

  testWidgets('挑了素材的插入段：摆出来，写清楚画面取自谁', (tester) async {
    await _pump(tester,
        unit: _inserted(),
        replacement: UnitReplacement.whole([7]),
        materialName: '厨房特写',
        onSegment: () {});

    expect(find.byKey(const Key('base-segment-card')), findsOneWidget);
    expect(find.text('厨房特写'), findsOneWidget);
  });

  testWidgets('还没切：按钮写「切分这一段」，并说清这一段从此只能用这一条',
      (tester) async {
    await _pump(tester,
        unit: _inserted(),
        replacement: UnitReplacement.whole([7]),
        onSegment: () {});

    expect(find.text('切分这一段'), findsOneWidget);
    expect(find.textContaining('只能用这一条'), findsOneWidget);
  });

  testWidgets('切过了：报镜头数，给「换一张底片」', (tester) async {
    await _pump(tester,
        unit: _inserted(pinned: 7, shots: const [
          Shot(startMs: 4000, endMs: 6500),
          Shot(startMs: 6500, endMs: 10000),
        ]),
        replacement: UnitReplacement.whole([7]),
        onSegment: () {},
        onUnpin: () {});

    expect(find.text('2 个'), findsOneWidget);
    expect(find.byKey(const Key('base-unpin-button')), findsOneWidget);
    expect(find.text('重新切分'), findsOneWidget);
  });

  testWidgets('还没挑素材：按钮灰着，但要说为什么', (tester) async {
    await _pump(tester,
        unit: _inserted(),
        replacement: UnitReplacement.keepOriginal(),
        onSegment: () {});

    final button = tester.widget<FilledButton>(
        find.byKey(const Key('base-segment-button')));
    expect(button.onPressed, isNull);
    // 「画面取自」那一行和提示里都会提到，关键是**说了为什么不能切**
    expect(find.textContaining('先在右边挑一条'), findsOneWidget);
  });

  testWidgets('正在切：不摆按钮，摆一句在动的话——切分要等一会儿',
      (tester) async {
    await _pump(tester,
        unit: _inserted(),
        replacement: UnitReplacement.whole([7]),
        segmenting: true,
        onSegment: () {});

    expect(find.byKey(const Key('base-segmenting')), findsOneWidget);
    expect(find.byKey(const Key('base-segment-button')), findsNothing);
  });

  testWidgets('点切分真的调回去', (tester) async {
    var tapped = 0;
    await _pump(tester,
        unit: _inserted(),
        replacement: UnitReplacement.whole([7]),
        onSegment: () => tapped++);

    await tester.tap(find.byKey(const Key('base-segment-button')));
    expect(tapped, 1);
  });

  testWidgets('刚切完还没打标：说清楚搜不出东西，并给打标的入口',
      (tester) async {
    await _pump(tester,
        unit: _inserted(pinned: 7, shots: const [
          Shot(startMs: 4000, endMs: 6500),
          Shot(startMs: 6500, endMs: 10000),
        ]).copyWith(tagsStale: true),
        replacement: UnitReplacement.whole([7]),
        onSegment: () {},
        onRetag: () {});

    expect(find.textContaining('还没打标'), findsOneWidget);
    expect(find.byKey(const Key('base-retag-button')), findsOneWidget);
  });

  testWidgets('打完标就不再摆那句话', (tester) async {
    await _pump(tester,
        unit: _inserted(pinned: 7, shots: const [
          Shot(startMs: 4000, endMs: 10000),
        ]),
        replacement: UnitReplacement.whole([7]),
        onSegment: () {},
        onRetag: () {});

    expect(find.byKey(const Key('base-retag-row')), findsNothing);
  });

  testWidgets('正在打标：摆一句在动的话，不摆按钮', (tester) async {
    await _pump(tester,
        unit: _inserted(pinned: 7, shots: const [
          Shot(startMs: 4000, endMs: 10000),
        ]).copyWith(tagsStale: true),
        replacement: UnitReplacement.whole([7]),
        retagging: true,
        onSegment: () {},
        onRetag: () {});

    expect(find.textContaining('正在逐镜看图打标'), findsOneWidget);
    expect(find.byKey(const Key('base-retag-button')), findsNothing);
  });
}
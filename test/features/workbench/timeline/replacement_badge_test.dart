import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

const _durationMs = 10000;
const _viewportWidth = 600.0;

/// U1 = 0~5000（S1 0~2000、S2 2000~5000），U2 = 5000~10000（S1 整段）
SegmentationEditorController _editor() => SegmentationEditorController(
      sentences: const [],
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 5000,
          transcript: '前半段',
          shots: [
            Shot(startMs: 0, endMs: 2000),
            Shot(startMs: 2000, endMs: 5000),
          ],
        ),
        SemanticUnit(
          index: 1,
          startMs: 5000,
          endMs: _durationMs,
          transcript: '后半段',
          shots: [Shot(startMs: 5000, endMs: _durationMs)],
        ),
      ],
      durationMs: _durationMs,
      fps: 30,
    );

late List<(int, int?)> jumps;

Future<void> _pump(
  WidgetTester tester, {
  required List<UnitReplacement> replacements,
}) async {
  jumps = [];
  final playhead = ValueNotifier<int>(0);
  addTearDown(playhead.dispose);
  tester.view.physicalSize = const Size(_viewportWidth, 500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: _viewportWidth,
        height: 500,
        child: TimelineView(
          controller: _editor(),
          // 每像素 20ms：U1 占 0~250px，U2 占 250~500px
          geometry: const TimelineGeometry(
              durationMs: _durationMs, msPerPx: 20, scrollPx: 0),
          playhead: playhead,
          onSeek: (_) {},
          onGeometryChanged: (_) {},
          replacements: replacements,
          onReplacementBadgeTap: (u, s) => jumps.add((u, s)),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// U1 整体替换挑了 3 条
List<UnitReplacement> _whole3() => [
      UnitReplacement.whole(const [101, 102, 103]),
      UnitReplacement.keepOriginal(),
    ];

/// U1 的 S2 挑了 2 条
List<UnitReplacement> _perShot2() => [
      UnitReplacement.perShot(const {
        1: [201, 202],
      }),
      UnitReplacement.keepOriginal(),
    ];

TimelinePainter _painter(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((w) => w.painter)
    .whereType<TimelinePainter>()
    .first;

void main() {
  group('时间线上标出「这一段挑了几条」', () {
    testWidgets('挑过素材的单元与没挑的画得不一样', (tester) async {
      await _pump(tester, replacements: _whole3());
      final withBadge = _painter(tester);

      await _pump(tester, replacements: const []);
      final plain = _painter(tester);

      expect(withBadge.shouldRepaint(plain), isTrue,
          reason: '挑好了素材却在时间线上看不出来，回到时间线就断片了');
      expect(plain.shouldRepaint(plain), isFalse,
          reason: '没变还重画，播放时每秒白重画 30 次整条时间线');
    });

    testWidgets('点单元上的数字，跳到这个单元的替换面板', (tester) async {
      await _pump(tester, replacements: _whole3());

      // U1 块体是 0~250px，徽标在右上角
      final rect = Rect.fromLTRB(
          0, TimelineTracks.unitsTop, 250, TimelineTracks.unitsBottom);
      await tester.tapAt(ReplacementBadges.unitBadgeRect(rect)!.center);
      await tester.pumpAndSettle();

      expect(jumps, [(0, null)],
          reason: '徽标只说「这儿挑了 3 条」，看不到是哪三条；'
              '点它要能落到那一段的候选面板');
    });

    testWidgets('点镜头上的数字，跳到这个镜头', (tester) async {
      await _pump(tester, replacements: _perShot2());

      // S2 是 2000~5000ms → 100~250px
      final rect = Rect.fromLTRB(
          100, TimelineTracks.shotsTop, 250, TimelineTracks.shotsBottom);
      await tester.tapAt(ReplacementBadges.shotBadgeRect(rect)!.center);
      await tester.pumpAndSettle();

      expect(jumps, [(0, 1)]);
    });

    testWidgets('没挑素材的地方点下去不会误跳', (tester) async {
      await _pump(tester, replacements: const []);

      final rect = Rect.fromLTRB(
          0, TimelineTracks.unitsTop, 250, TimelineTracks.unitsBottom);
      await tester.tapAt(ReplacementBadges.unitBadgeRect(rect)!.center);
      await tester.pumpAndSettle();

      expect(jumps, isEmpty);
    });
  });

  group('徽标几何：块体放不下就不画', () {
    test('窄块体返回 null——半个徽标比没有更糟', () {
      const narrow = Rect.fromLTWH(0, 0, 10, 22);

      expect(ReplacementBadges.unitBadgeRect(narrow), isNull);
      expect(ReplacementBadges.shotBadgeRect(narrow), isNull);
    });

    test('徽标贴在块体右上角，不越界', () {
      const block = Rect.fromLTWH(100, 40, 200, 22);

      final badge = ReplacementBadges.unitBadgeRect(block)!;
      expect(badge.right, lessThanOrEqualTo(block.right));
      expect(badge.top, greaterThanOrEqualTo(block.top));
      expect(badge.bottom, lessThanOrEqualTo(block.bottom));
    });
  });
}

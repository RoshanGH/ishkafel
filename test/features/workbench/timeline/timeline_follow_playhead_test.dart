import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

const _viewportWidth = 800.0;
const _durationMs = 96000;

SegmentationEditorController _controller() => SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: _durationMs,
          transcript: '整段台词',
          shots: [Shot(startMs: 0, endMs: _durationMs)],
        ),
      ],
      durationMs: _durationMs,
      fps: 30,
      sentences: const [],
    );

Future<void> _pump(
  WidgetTester tester, {
  required TimelineGeometry geometry,
  required ValueNotifier<int> playhead,
  required ValueChanged<TimelineGeometry> onGeometryChanged,
}) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: _viewportWidth,
          height: 260,
          child: TimelineView(
            controller: _controller(),
            geometry: geometry,
            playhead: playhead,
            onSeek: (_) {},
            onGeometryChanged: onGeometryChanged,
          ),
        ),
      ),
    ));

void main() {
  group('时间线跟随播放头（放大后播放，播放头会跑出可视区）', () {
    testWidgets('播放头移出右边界时自动滚动，把它带回可视区', (tester) async {
      // 放大 8 倍：视口只覆盖全片的八分之一
      final zoomed = TimelineGeometry.fit(
              durationMs: _durationMs, viewportWidthPx: _viewportWidth)
          .zoomAt(0, 8, viewportWidthPx: _viewportWidth);
      final playhead = ValueNotifier<int>(0);
      addTearDown(playhead.dispose);
      TimelineGeometry? latest;

      await _pump(
        tester,
        geometry: zoomed,
        playhead: playhead,
        onGeometryChanged: (g) => latest = g,
      );

      // 播放推进到视口之外
      const aheadMs = 60000;
      expect(zoomed.msToPx(aheadMs), greaterThan(_viewportWidth),
          reason: '前提：该位置在当前视口右侧之外');

      playhead.value = aheadMs;
      await tester.pump();

      expect(latest, isNotNull,
          reason: '播放头跑出可视区却不滚动，用户放大后一播放就"丢失"了播放头');
      final x = latest!.msToPx(aheadMs);
      expect(x, greaterThanOrEqualTo(0));
      expect(x, lessThanOrEqualTo(_viewportWidth));
    });

    testWidgets('播放头仍在可视区内时不滚动，不跟用户的浏览位置抢', (tester) async {
      final zoomed = TimelineGeometry.fit(
              durationMs: _durationMs, viewportWidthPx: _viewportWidth)
          .zoomAt(0, 8, viewportWidthPx: _viewportWidth);
      final playhead = ValueNotifier<int>(0);
      addTearDown(playhead.dispose);
      var callCount = 0;

      await _pump(
        tester,
        geometry: zoomed,
        playhead: playhead,
        onGeometryChanged: (_) => callCount++,
      );

      // 往前推一点点，仍在视口内
      final insideMs = zoomed.pxToMs(_viewportWidth / 2).round();
      playhead.value = insideMs;
      await tester.pump();

      expect(callCount, 0,
          reason: '播放头还在视野里就滚动，会让画面无谓地抖动，也会跟用户'
              '正在查看的位置抢控制权');
    });

    testWidgets('未放大（整片铺满视口）时永远不滚动', (tester) async {
      final fit = TimelineGeometry.fit(
          durationMs: _durationMs, viewportWidthPx: _viewportWidth);
      final playhead = ValueNotifier<int>(0);
      addTearDown(playhead.dispose);
      var callCount = 0;

      await _pump(
        tester,
        geometry: fit,
        playhead: playhead,
        onGeometryChanged: (_) => callCount++,
      );

      playhead.value = _durationMs - 1;
      await tester.pump();

      expect(callCount, 0, reason: 'fit 状态下整片都在视口里，没有滚动的必要');
    });
  });
}

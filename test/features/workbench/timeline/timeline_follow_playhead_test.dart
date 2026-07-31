import 'package:flutter/gestures.dart';
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

    testWidgets('用户手动浏览后暂停跟随，不把视口从用户脚下拽走', (tester) async {
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

      // 用户滚轮浏览到别处（模拟播放中想看看后面的内容）
      final center = tester.getCenter(find.byType(TimelineView));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(200, 0)));
      await tester.pump();
      latest = null;

      // 播放继续推进，播放头此时在视口之外
      playhead.value = 60000;
      await tester.pump();

      expect(latest, isNull,
          reason: '用户刚手动浏览过，下一个 tick（≤33ms）就把视口拽回去，'
              '等于不让人看——剪映/FCP 都是用户一交互就临时停跟随');
    });

    testWidgets('播放头重新进入视野后恢复跟随', (tester) async {
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

      final center = tester.getCenter(find.byType(TimelineView));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(const Offset(200, 0)));
      await tester.pump();

      // 播放头回到当前视口内 → 视为用户已经"追上"，恢复跟随
      final insideMs = zoomed.pxToMs(_viewportWidth / 2).round();
      playhead.value = insideMs;
      await tester.pump();
      latest = null;

      // 再次跑出视口，这次应该重新跟随
      playhead.value = 60000;
      await tester.pump();

      expect(latest, isNotNull,
          reason: '暂停跟随不能是永久的，否则用户浏览一次之后播放头就再也'
              '不会被带回来了');
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

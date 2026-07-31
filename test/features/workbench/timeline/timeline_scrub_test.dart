import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

const _durationMs = 10000;
const _viewportWidth = 500.0;

/// 10 秒 / 500px → 每像素 20ms（正好铺满视口，滚不动）
TimelineGeometry _geometry({double msPerPx = 20}) =>
    TimelineGeometry(durationMs: _durationMs, msPerPx: msPerPx, scrollPx: 0);

SegmentationEditorController _editor() => SegmentationEditorController(
      sentences: const [],
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 5000,
          transcript: '前半段',
          shots: [Shot(startMs: 0, endMs: 5000)],
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

late List<int> seeks;
late int scrubStarts;
late int scrubEnds;
late ValueNotifier<int> playhead;
late TimelineGeometry geometry;

Future<void> _pump(WidgetTester tester,
    {bool readOnly = false, double msPerPx = 20}) async {
  seeks = [];
  scrubStarts = 0;
  scrubEnds = 0;
  playhead = ValueNotifier<int>(0);
  geometry = _geometry(msPerPx: msPerPx);
  addTearDown(playhead.dispose);

  tester.view.physicalSize = const Size(_viewportWidth, 400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => SizedBox(
          width: _viewportWidth,
          height: 400,
          child: TimelineView(
            controller: _editor(),
            geometry: geometry,
            playhead: playhead,
            readOnly: readOnly,
            onSeek: (ms) {
              seeks.add(ms);
              playhead.value = ms;
            },
            onGeometryChanged: (g) => setState(() => geometry = g),
            onScrubStart: () => scrubStarts++,
            onScrubEnd: () => scrubEnds++,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 刻度尺纵向中点
double get _rulerY => TimelineTracks.rulerTop + TimelineTracks.rulerH / 2;

void main() {
  group('拖动播放头（红线）连续定位', () {
    testWidgets('在刻度尺上按住拖动会持续 seek，而不是滚动时间线', (tester) async {
      await _pump(tester);

      final gesture =
          await tester.startGesture(Offset(50, _rulerY), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(seeks.length, greaterThanOrEqualTo(2),
          reason: '拖动过程中要连续定位，用户才能看着画面找位置；'
              '只在松手时跳一次等于闭着眼睛拖');
      expect(seeks.last, closeTo(200 * 20, 40),
          reason: '终点 x=200px、每像素 20ms → 约 4000ms');
      expect(geometry.scrollPx, 0,
          reason: '在刻度尺上拖动是拖播放头，不是拖时间线——'
              '两个动作抢同一个手势时，播放头优先');
    });

    testWidgets('抓住红线本身也能拖（不必精确点在刻度尺上）', (tester) async {
      await _pump(tester);
      playhead.value = 2000; // x = 100px
      await tester.pump();

      // 从镜头轨那一行、红线附近按下
      final y = TimelineTracks.shotsTop + TimelineTracks.shotsH / 2;
      final gesture = await tester.startGesture(Offset(102, y),
          kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(seeks, isNotEmpty,
          reason: '红线是最显眼的抓手，用户会直接去拖它');
      expect(seeks.last, closeTo(162 * 20, 60));
    });

    testWidgets('离红线远的地方按下仍然是滚动时间线', (tester) async {
      // 放大到总宽 1000px（视口 500px），才有可滚动的余量
      await _pump(tester, msPerPx: 10);
      playhead.value = 0;
      await tester.pump();

      final y = TimelineTracks.shotsTop + TimelineTracks.shotsH / 2;
      final gesture =
          await tester.startGesture(Offset(300, y), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(-80, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(seeks, isEmpty);
      expect(geometry.scrollPx, greaterThan(0),
          reason: '空白处横拖仍是浏览时间线，这个既有手势不能被抢走');
    });
  });

  group('拖动期间的播放状态', () {
    testWidgets('开始拖时通知一次、松手时通知一次', (tester) async {
      await _pump(tester);

      final gesture =
          await tester.startGesture(Offset(50, _rulerY), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(scrubStarts, 1);
      expect(scrubEnds, 1,
          reason: '少发一次 end，播放就永远恢复不回来了');
    });

    testWidgets('不是拖播放头（普通滚动）时不发这两个通知', (tester) async {
      await _pump(tester);

      final y = TimelineTracks.shotsTop + TimelineTracks.shotsH / 2;
      final gesture =
          await tester.startGesture(Offset(300, y), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(scrubStarts, 0);
      expect(scrubEnds, 0);
    });
  });

  group('边界与只读', () {
    testWidgets('拖出左右两端都夹到片头片尾，不会出现负数或超长', (tester) async {
      await _pump(tester);

      final gesture =
          await tester.startGesture(Offset(50, _rulerY), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(-400, 0));
      await tester.pump();
      expect(seeks.last, 0);

      await gesture.moveBy(const Offset(2000, 0));
      await tester.pump();
      expect(seeks.last, _durationMs);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('只读回看也能拖——它只是定位，不改任何数据', (tester) async {
      await _pump(tester, readOnly: true);

      final gesture =
          await tester.startGesture(Offset(50, _rulerY), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(seeks, isNotEmpty,
          reason: '只读禁的是「改数据」，浏览片子本身必须照常');
    });
  });
}

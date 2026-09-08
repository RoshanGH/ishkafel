import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

/// 双击字幕轨上的块 → 就地改这一镜的字幕。
///
/// 用户 2026-09-08：「我双击那个字幕轨上的那个字幕的时候，能不能在那个地方改？」
void main() {
  const viewportWidth = 1600.0;
  const durationMs = 10000;

  late SegmentationEditorController controller;
  late List<(int, int)> edited;
  late DateTime now;

  Future<void> pump(WidgetTester tester) async {
    controller = SegmentationEditorController(
      initialUnits: const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: durationMs,
          transcript: '整段台词',
          shots: [
            Shot(startMs: 0, endMs: 4000),
            Shot(startMs: 4000, endMs: durationMs),
          ],
        ),
      ],
      durationMs: durationMs,
      fps: 30,
      sentences: const [],
    );
    edited = [];
    now = DateTime.utc(2026, 9, 8);
    final playhead = ValueNotifier<int>(0);
    addTearDown(playhead.dispose);

    tester.view.physicalSize = const Size(viewportWidth, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: viewportWidth,
          height: 500,
          child: TimelineView(
            controller: controller,
            geometry: const TimelineGeometry(
                durationMs: durationMs, msPerPx: 10, scrollPx: 0),
            playhead: playhead,
            onSeek: (_) {},
            onGeometryChanged: (_) {},
            onEditSubtitleBlock: (u, s, _) => edited.add((u, s)),
            clock: () => now,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 字幕轨上第二镜的中间
  Offset onSubs() => Offset(
      700, (TimelineTracks.subsTop + TimelineTracks.subsBottom) / 2);

  /// 带**硬件时间戳**点一下。
  ///
  /// 双击判定用的是事件自带的时间戳，不是墙钟——第一下会引发选中与重建
  /// （真机实测 230ms），拿墙钟量的话第二下已经排到 353ms，双击时灵时不灵。
  /// `tester.tapAt` 不带时间戳（恒为 0），所以这里手动发。
  Future<void> tapAtTime(WidgetTester tester, Offset at, Duration ts) async {
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(p.down(at, timeStamp: ts));
    await tester.sendEventToBinding(p.up(timeStamp: ts));
    await tester.pumpAndSettle();
  }

  testWidgets('单击只是选中，不弹', (tester) async {
    await pump(tester);

    await tapAtTime(tester, onSubs(), const Duration(seconds: 1));

    expect(edited, isEmpty);
    expect(controller.selection?.shotIndex, 1);
  });

  testWidgets('双击交出这一镜的下标', (tester) async {
    await pump(tester);

    await tapAtTime(tester, onSubs(), const Duration(seconds: 1));
    await tapAtTime(
        tester, onSubs(), const Duration(seconds: 1, milliseconds: 60));

    expect(edited, [(0, 1)]);
  });

  testWidgets('两次点击隔太久算两次单击，不弹', (tester) async {
    await pump(tester);

    await tapAtTime(tester, onSubs(), const Duration(seconds: 1));
    await tapAtTime(tester, onSubs(), const Duration(seconds: 3));

    expect(edited, isEmpty);
  });
}

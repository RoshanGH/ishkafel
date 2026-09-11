import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/segmentation_editor_controller.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_hit_tester.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_view.dart';

/// 字幕轨上一句一段，各自能拖。
///
/// 用户 2026-09-11：「像剪映一样：它不是共用一个中间接口，而是各自成一段……
/// 它们不能重叠，可以挨在一起，也可以中间留出空出来的地方。」
///
/// 这一镜 0~4000ms，msPerPx=4 → 块体是 0~1000px（整块都在 1600px 的视口里，
/// 否则超出视口的部分根本收不到指针）。1px ≈ 4ms。
///
/// 两段字幕：0~1000ms（px 1~250）、2000~3000ms（px 500~750）。
void main() {
  const viewportWidth = 1600.0;
  const durationMs = 10000;

  late List<SubtitleLine> lines;
  late List<({int unit, int shot, List<SubtitleLine> lines})> committed;

  Future<void> pump(WidgetTester tester, {bool readOnly = false}) async {
    final controller = SegmentationEditorController(
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
    lines = const [
      SubtitleLine(startMs: 0, endMs: 1000, text: '看看啊'),
      SubtitleLine(startMs: 2000, endMs: 3000, text: '哇这也太猛了'),
    ];
    committed = [];
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
                durationMs: durationMs, msPerPx: 4, scrollPx: 0),
            playhead: playhead,
            onSeek: (_) {},
            onGeometryChanged: (_) {},
            readOnly: readOnly,
            // 只有第一镜有字幕（第二镜没换素材）
            subtitleLinesOf: (u, s) => s == 0 ? lines : const [],
            onSubtitleChanged: (u, s, v) =>
                committed.add((unit: u, shot: s, lines: v)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  final y = (TimelineTracks.subsTop + TimelineTracks.subsBottom) / 2;

  /// 从 [fromX] 拖到 [toX]
  Future<void> drag(WidgetTester tester, double fromX, double toX) async {
    final g = await tester.startGesture(Offset(fromX, y),
        kind: PointerDeviceKind.mouse);
    await tester.pump();
    await g.moveTo(Offset(toX, y));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('拖第二段的左边缘 → 改起点，终点不动', (tester) async {
    await pump(tester);
    // 第二段 2000~3000ms，块体从 1px 起（左边留了 1px 边距）
    await drag(tester, 501, 626);

    expect(committed, hasLength(1));
    expect(committed.single.lines[1].startMs, closeTo(2500, 20));
    expect(committed.single.lines[1].endMs, 3000);
  });

  testWidgets('拖右边缘 → 改终点', (tester) async {
    await pump(tester);
    await drag(tester, 748, 848);
    expect(committed.single.lines[1].endMs, closeTo(3400, 20));
    expect(committed.single.lines[1].startMs, 2000);
  });

  testWidgets('拖中间 → 整段平移，长度一分不变', (tester) async {
    await pump(tester);
    await drag(tester, 600, 700);
    final moved = committed.single.lines[1];
    expect(moved.startMs, closeTo(2400, 20));
    expect(moved.endMs - moved.startMs, 1000);
  });

  testWidgets('往左拖过头：顶在前一段的尾巴上，不重叠', (tester) async {
    await pump(tester);
    await drag(tester, 600, 100);
    expect(committed.single.lines[1].startMs, 1000,
        reason: '两句字同时挂在画面上就是打架');
  });

  testWidgets('往右拖过头：顶在这一镜的末尾，不许拖出去', (tester) async {
    await pump(tester);
    await drag(tester, 600, 1100);
    expect(committed.single.lines[1].endMs, 4000);
    expect(committed.single.lines[1].endMs -
        committed.single.lines[1].startMs, 1000);
  });

  testWidgets('拖完才提交一次——每像素提交等于每像素重烧一遍字幕',
      (tester) async {
    await pump(tester);
    final g = await tester.startGesture(Offset(600, y),
        kind: PointerDeviceKind.mouse);
    await tester.pump();
    for (var x = 610; x <= 700; x += 10) {
      await g.moveTo(Offset(x.toDouble(), y));
      await tester.pump();
    }
    expect(committed, isEmpty, reason: '松手之前一次都不该提交');
    await g.up();
    await tester.pumpAndSettle();
    expect(committed, hasLength(1));
  });

  testWidgets('没拖动就不提交', (tester) async {
    await pump(tester);
    await drag(tester, 600, 600);
    expect(committed, isEmpty);
  });

  testWidgets('只读回看下拖不动', (tester) async {
    await pump(tester, readOnly: true);
    await drag(tester, 600, 700);
    expect(committed, isEmpty);
  });

  testWidgets('没换素材的那一镜没有段可抓', (tester) async {
    await pump(tester);
    // 第二镜从 1000px 起，那儿没有字幕
    await drag(tester, 1200, 1300);
    expect(committed, isEmpty);
  });
}

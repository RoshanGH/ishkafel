import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_track.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_geometry.dart';
import 'package:ishkafel/features/workbench/timeline/timeline_painter.dart';

/// **画布没重画 = 用户看到的是「拖不动」。**
///
/// 2026-09-11 用户：「字幕拖拽的时长拖拽好卡，连着拖两三下才会动。」
/// 根因不在手势也不在算法——拖动改的是 TimelineView 自己那份临时数据，
/// 而 [TimelinePainter.shouldRepaint] 里没有它，于是整个拖动过程一帧都不重画。
/// 松手落库之后也一样（改字幕不动 units），要等下一次鼠标移动蹭出一次重画。
///
/// 这类问题 widget 测试很难断言（重画与否不体现在 widget 树上），
/// 但它的机制就是这个函数——直接钉它。
void main() {
  final units = [
    const SemanticUnit(
      uid: 'u0',
      index: 0,
      startMs: 0,
      endMs: 4000,
      transcript: 'U1',
      shots: [Shot(startMs: 0, endMs: 4000)],
    ),
  ];

  TimelinePainter painter({
    ({int unitIndex, int shotIndex, int lineIndex, List<SubtitleLine> lines})?
        dragging,
    SubtitleTrack track = const SubtitleTrack.empty(),
  }) =>
      TimelinePainter(
        units: units,
        selection: null,
        geometry: const TimelineGeometry(
            durationMs: 4000, msPerPx: 4, scrollPx: 0),
        playheadMs: 0,
        textCache: TextLayoutCache(),
        subtitleDragging: dragging,
        subtitleTrack: track,
      );

  test('拖动中每挪一点都要重画——不重画，人看到的就是「拖不动」', () {
    final a = painter(
        dragging: (
          unitIndex: 0,
          shotIndex: 0,
          lineIndex: 1,
          lines: const [SubtitleLine(startMs: 0, endMs: 500, text: 'a')],
        ));
    final b = painter(
        dragging: (
          unitIndex: 0,
          shotIndex: 0,
          lineIndex: 1,
          // 只有时间变了：这正是拖动过程中唯一在变的东西
          lines: const [SubtitleLine(startMs: 0, endMs: 800, text: 'a')],
        ));

    expect(b.shouldRepaint(a), isTrue);
  });

  test('开始拖 / 松手 也要重画（那一段要亮起来、暗回去）', () {
    final idle = painter();
    final dragging = painter(
        dragging: (
          unitIndex: 0,
          shotIndex: 0,
          lineIndex: 0,
          lines: const [SubtitleLine(startMs: 0, endMs: 500, text: 'a')],
        ));

    expect(dragging.shouldRepaint(idle), isTrue);
    expect(idle.shouldRepaint(dragging), isTrue);
  });

  test('改完字幕落了库也要重画——改字幕不动 units，光靠 units 比不出来', () {
    const slot = SubtitleSlot(unitUid: 'u0', shotIndex: 0);
    final before = painter();
    final after = painter(
        track: const SubtitleTrack.empty().withLines(
            slot, const [SubtitleLine(startMs: 0, endMs: 500, text: '新的')]));

    expect(after.shouldRepaint(before), isTrue);
  });

  test('什么都没变就别重画——时间线每帧重绘代价不小', () {
    expect(painter().shouldRepaint(painter()), isFalse);
  });
}

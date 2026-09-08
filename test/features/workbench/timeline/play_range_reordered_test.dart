import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// **双击一格要播的那一段，也得按下标问成片轴。**
///
/// 2026-09-08 真机：「U6 不能正常播放」。双击传的是 `unit.endMs`，
/// 而 endMs 是开区间——「原片毫秒 → 成片毫秒」按「谁的原片区间盖住它」找，
/// 它落进的是相邻那一段。手加的单元被拖到最前之后（它在原片上的占位排在
/// 末尾），原片里最后那个单元的终点被算成了手加单元的成片起点 0，
/// 播放区间变成「从 104 秒播到 0 秒」，什么也放不出来。
///
/// 和画块体是同一个错误（见 timeline_painter 的 _unitPx/_shotPx）。
void main() {
  /// U1 手加（原片占位排在末尾），被拖到列表最前
  final units = <SemanticUnit>[
    const SemanticUnit(
        index: 0, startMs: 20000, endMs: 30000, transcript: '', hasSource: false),
    const SemanticUnit(
        index: 1,
        startMs: 0,
        endMs: 10000,
        transcript: '第一句',
        shots: [Shot(startMs: 0, endMs: 10000)]),
    const SemanticUnit(
        index: 2,
        startMs: 10000,
        endMs: 20000,
        transcript: '第二句',
        shots: [
          Shot(startMs: 10000, endMs: 15000),
          Shot(startMs: 15000, endMs: 20000),
        ]),
  ];

  final axis = ComposedTimeline.of(units: units, wholeDurations: const {});

  test('病态方向已经删掉了——想犯这个错都没有 API 可用', () {
    // 原来这里记录的是病灶本身：
    //   axis.toComposedMs(units[2].endMs) == 0   ← 应该是 30000
    // 一期重构把 toComposedMs 整个删了（见 TRD 四、一期），
    // 剩下的守卫在 test/architecture/no_source_ms_to_px_test.dart
    expect(axis.startOf(2), 20000);
  });

  test('按下标问：最后一个单元的成片区间是对的', () {
    final start = axis.startOf(2);
    final end = start + axis.durationOf(2);

    expect(start, 20000);
    expect(end, 30000);
    expect(end, greaterThan(start),
        reason: '区间翻转的话播放器收到「从 20 秒播到 0 秒」，什么也放不出来');
  });

  test('最后一镜同理——它的 endMs 等于所属单元的 endMs', () {
    expect(axis.composedShotStart(2, 1), 25000);
    expect(axis.composedShotEnd(2, 1), 30000);
  });

  test('前面几格本来就没问题，改法不能把它们弄坏', () {
    expect(axis.startOf(0), 0);
    expect(axis.startOf(1), 10000);
    expect(axis.composedShotStart(1, 0), 10000);
    expect(axis.composedShotEnd(1, 0), 20000);
  });
}

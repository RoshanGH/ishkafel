import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/boundary_trace_index.dart';
import 'package:ishkafel/core/analysis/shot_boundary_detector.dart';
import 'package:ishkafel/core/time/timecode.dart';

/// 切点是**原始毫秒**检出来的，镜头边界一律**吸到帧上**——两条线都这样。
/// 中间不做一次对齐，拿 `shot.startMs` 去查原始键就绝大多数查不中，
/// 「这一刀是怎么定出来的」于是大面积缺失，而缺了不报错。
///
/// 2026-09-15 给底片切分补这一项时量出「7 镜只贴上 2 条」，才摸到全片那条
/// 线也一样。这组测试把对齐这一步钉死。
void main() {
  ShotBoundaryCandidate at(int ms, {bool confirmed = true}) =>
      ShotBoundaryCandidate(
        ms: ms,
        sceneScore: 0.42,
        histDistance: 0.31,
        confidence: confirmed
            ? BoundaryConfidence.confirmed
            : BoundaryConfidence.uncertain,
      );

  test('键按帧对齐，和镜头边界用同一套算法', () {
    // 30fps：一帧 33.33ms，3435 吸到 3433
    final traces = boundaryTracesByFrame({3435: at(3435)}, 30);

    expect(traces.keys.single, alignToFrame(3435, 30));
    expect(traces.containsKey(3435), isFalse,
        reason: '原始键留着没用——镜头那边拿的是对齐后的值');
  });

  test('对齐之后查得中：这正是过去查不中的那一下', () {
    const rawCut = 3435;
    final aligned = alignToFrame(rawCut, 30);
    final traces = boundaryTracesByFrame({rawCut: at(rawCut)}, 30);

    expect(traces[aligned], isNotNull);
    expect(traces[aligned]!.sceneScore, 0.42);
  });

  test('判定结论带过来：直接确认 / 灰区经复核', () {
    expect(boundaryTracesByFrame({1000: at(1000)}, 30).values.single.decision,
        'confirmed');
    expect(
        boundaryTracesByFrame({1000: at(1000, confirmed: false)}, 30)
            .values
            .single
            .decision,
        'reviewed');
  });

  test('读不出帧率（fps=0）时不乱动键——原样索引', () {
    final traces = boundaryTracesByFrame({3435: at(3435)}, 0);

    expect(traces.keys.single, 3435);
  });

  test('没有明细就是空表，调用方据此原样返回', () {
    expect(boundaryTracesByFrame(const {}, 30), isEmpty);
  });

  test('两个原始切点对齐到同一帧：不崩，留一条', () {
    final traces = boundaryTracesByFrame({3434: at(3434), 3435: at(3435)}, 30);

    expect(traces.length, 1);
  });
}

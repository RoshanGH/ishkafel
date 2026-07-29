import '../models/semantic_unit.dart';
import '../models/shot.dart';
import 'boundary_snapper.dart';

/// 语义单元草稿（LLM 语义分组的输出：粗边界 + 台词）
class UnitDraft {
  final int startMs;
  final int endMs;
  final String transcript;

  const UnitDraft({
    required this.startMs,
    required this.endMs,
    required this.transcript,
  });
}

/// 两层构树（纯算法）：
/// 1. 内部单元边界经 BoundarySnapper 吸附（首边界恒为 0，尾边界恒为片长）
/// 2. 每单元内部按落入其中的镜头边界切出 shots，保证严格包含与无缝覆盖
class SegmentationBuilder {
  final BoundarySnapper snapper;

  const SegmentationBuilder({this.snapper = const BoundarySnapper()});

  List<SemanticUnit> build({
    required List<UnitDraft> drafts,
    required List<int> shotBoundaryMs,
    required List<int> silenceValleyMs,
    required int videoDurationMs,
    required double fps,
  }) {
    if (drafts.isEmpty) return const [];

    // 镜头边界先统一帧对齐、去重、排序：吸附结果与 inner 分割必须使用同一份
    // 对齐后的边界，否则吸附得到帧对齐值而 inner 分割仍用原始值，会在两者
    // 差值处产出毫秒级 sliver shot，且该边界不满足"帧对齐"约束。
    final alignedShotBoundaries = shotBoundaryMs
        .map((b) => snapper.snapToFrame(b, fps))
        .toSet()
        .toList()
      ..sort();

    final frameWidthMs = fps > 0 ? (1000 / fps).round() : 1;

    final bounds = <int>[0];
    for (var i = 0; i < drafts.length - 1; i++) {
      var b = snapper.snap(
        drafts[i].endMs,
        shotBoundaries: alignedShotBoundaries,
        silenceValleys: silenceValleyMs,
        fps: fps,
      );
      // 吸附导致越过前一边界时回退为原位帧对齐；仍越界则强制递增一帧宽度
      if (b <= bounds.last) b = snapper.snapToFrame(drafts[i].endMs, fps);
      if (b <= bounds.last) b = bounds.last + frameWidthMs;

      // 夹紧到 [上一边界+一帧, 片长-一帧]，避免 draft.endMs 逼近/超出片长时
      // 帧对齐把内部边界推到 >= videoDurationMs，产出零/负时长单元。
      // 若该区间本身无效（片长过短装不下所有边界），退化为「上一边界+一帧」，
      // 仅保证严格递增，这是最简单的正确兜底。
      final lowerBound = bounds.last + frameWidthMs;
      final upperBound = videoDurationMs - frameWidthMs;
      if (upperBound >= lowerBound) {
        if (b < lowerBound) b = lowerBound;
        if (b > upperBound) b = upperBound;
      } else {
        b = lowerBound;
      }
      // 兜底：无论如何不得达到或超过片长，保证末尾追加的 videoDurationMs 严格更大
      if (b >= videoDurationMs) b = videoDurationMs - 1;
      bounds.add(b);
    }
    bounds.add(videoDurationMs);

    final units = <SemanticUnit>[];
    for (var i = 0; i < drafts.length; i++) {
      final start = bounds[i];
      final end = bounds[i + 1];
      final inner =
          alignedShotBoundaries.where((b) => b > start && b < end).toList()
            ..sort();
      final edges = [start, ...inner, end];
      units.add(SemanticUnit(
        index: i,
        startMs: start,
        endMs: end,
        transcript: drafts[i].transcript,
        shots: [
          for (var k = 0; k < edges.length - 1; k++)
            Shot(startMs: edges[k], endMs: edges[k + 1]),
        ],
      ));
    }
    return List.unmodifiable(units);
  }
}

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

    final bounds = <int>[0];
    for (var i = 0; i < drafts.length - 1; i++) {
      var b = snapper.snap(
        drafts[i].endMs,
        shotBoundaries: shotBoundaryMs,
        silenceValleys: silenceValleyMs,
        fps: fps,
      );
      // 吸附导致越过前一边界时回退为原位帧对齐；仍越界则强制递增一帧宽度
      if (b <= bounds.last) b = snapper.snapToFrame(drafts[i].endMs, fps);
      if (b <= bounds.last) b = bounds.last + (1000 / fps).round();
      bounds.add(b);
    }
    bounds.add(videoDurationMs);

    final units = <SemanticUnit>[];
    for (var i = 0; i < drafts.length; i++) {
      final start = bounds[i];
      final end = bounds[i + 1];
      final inner = shotBoundaryMs.where((b) => b > start && b < end).toList()
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

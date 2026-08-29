/// 一条候选素材要怎么放进坑位：从第几毫秒起、截多长、按几倍速播。
///
/// **替换裂变原本是「整条压缩」**——不管素材多长都拉伸到坑位长度。原片的
/// 快切镜头是 0.4~1 秒，而素材库里的分镜普遍 4~30 秒，于是短坑位必然出现
/// 10~30 倍快放：真机上一条 34 镜的片子里，坑位不到 1.5 秒的有 13 个，
/// 将近四成；最短那一镜（433ms）整页 50 条候选里倍速最接近 1 的是 9.44。
///
/// 人拿剪辑软件做这件事的方式是**从长素材里截一段**。这个文件就是那件事。
library;

/// 素材短于坑位多少以内还算自然。
///
/// 1.25 倍：略快一点人眼看不出来，再快就是可见的快进了。
/// 这个数只用来判「合不合适」，不改变实际倍速
const double _naturalSlowdown = 1.25;

class CandidateTrim {
  /// 从素材的第几毫秒开始截
  final int startMs;

  /// 截多长（素材内的时长，不是成片时长）
  final int durationMs;

  /// 播放倍速。截得出等长的一段时恒为 1.0；素材不够长时小于 1（放慢）
  final double speed;

  const CandidateTrim({
    required this.startMs,
    required this.durationMs,
    required this.speed,
  });

  /// 这条素材配这个坑位合不合适。false = 只能靠明显的变速硬凑
  bool get isNatural => speed >= 1 / _naturalSlowdown - 1e-9;
}

/// 算这条素材该怎么放进坑位。
///
/// [startMs] 是人（或 Agent）指定的起点；不给就自动取**中段**——素材开头
/// 常有转场和黑帧，中段画面最稳。
CandidateTrim trimFor({
  required int materialMs,
  required int slotMs,
  int? startMs,
}) {
  // 量不到素材时长时不硬猜，退回整条压缩的老路（倍速由导出那头按实际时长算）
  if (materialMs <= 0 || slotMs <= 0) {
    return CandidateTrim(startMs: 0, durationMs: slotMs, speed: 1.0);
  }

  if (materialMs <= slotMs) {
    // 截不出来：整条用，放慢撑满坑位。这里如实给出倍速，
    // **该拦的是提交那一步**——在这儿假装没事，坏片子就流到成片里了
    return CandidateTrim(
      startMs: 0,
      durationMs: materialMs,
      speed: materialMs / slotMs,
    );
  }

  final latest = materialMs - slotMs;
  final from = startMs == null ? latest ~/ 2 : startMs.clamp(0, latest);
  return CandidateTrim(startMs: from, durationMs: slotMs, speed: 1.0);
}

/// 这条素材的取段起点能挪到哪儿——**界面拖动条的范围**。
class TrimRange {
  final int minStartMs;
  final int maxStartMs;

  const TrimRange({required this.minStartMs, required this.maxStartMs});

  /// 有没有挪的余地。素材不比坑位长时没得挪（整条都要用上还不够）
  bool get canAdjust => maxStartMs > minStartMs;
}

/// 算取段起点的可选范围。
///
/// 真机数据：一条 34 镜的片子里，102 条候选中有 74 条素材比坑位长 3 倍以上，
/// 最夸张的 24 倍（19 秒素材配 0.8 秒坑位）。「截哪一段」的选择空间很大，
/// 自动取中段只是个起点，人得能自己挪。
TrimRange trimRange({required int materialMs, required int slotMs}) {
  if (materialMs <= 0 || slotMs <= 0 || materialMs <= slotMs) {
    return const TrimRange(minStartMs: 0, maxStartMs: 0);
  }
  return TrimRange(minStartMs: 0, maxStartMs: materialMs - slotMs);
}

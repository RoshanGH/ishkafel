/// 一条候选素材要怎么放进坑位：从第几毫秒起、用多长的一段、按几倍速播。
///
/// **视觉镜头替换一律「整条变速铺满坑位」**——不管素材多长，都把它（从
/// [CandidateTrim.startMs] 起的那一整段）压进原镜头的时长里，绝不自动截断。
/// 产品负责人 2026-09-09 定的：「替换裂变这个模块下的视觉镜头替换，
/// 全部走自动变速充满原镜头时长的方案。」
///
/// 这里曾经是「从长素材里截一段」：原片快切镜头 0.4~1 秒，素材库里的分镜
/// 普遍 4~30 秒，整条压缩就是十几二十倍快放，所以改成了截中段、倍速回到
/// 1.0。代价是**画面被剪掉了大半**——真机上看到的就是「本该变速的镜头被
/// 剪切了」。两条路各有代价，选哪条是产品判断，不是这层能替他决定的。
///
/// 倍速的代价如实往上报（候选卡上的倍速徽标、审核页的「加速 N×」），
/// 让人挑素材的时候就看得见，而不是导出来才发现。
library;

/// 快慢多少以内还算自然。
///
/// 1.25 倍：略快或略慢一点人眼看不出来，再多就是可见的快进/慢放了。
/// 这个数只用来判「合不合适」，不改变实际倍速
const double _naturalWindow = 1.25;

class CandidateTrim {
  /// 从素材的第几毫秒开始用。不指定就是 0——**整条都要**
  final int startMs;

  /// 用多长的一段（素材内的时长，不是成片时长）
  final int durationMs;

  /// 播放倍速。>1 是加速，<1 是放慢；[durationMs] 恰好等于坑位时才是 1.0
  final double speed;

  const CandidateTrim({
    required this.startMs,
    required this.durationMs,
    required this.speed,
  });

  /// 这条素材配这个坑位合不合适。false = 只能靠明显的变速硬凑
  bool get isNatural =>
      speed <= _naturalWindow + 1e-9 && speed >= 1 / _naturalWindow - 1e-9;
}

/// 算这条素材该怎么放进坑位。
///
/// [startMs] 是人（或 Agent）指定的起点——素材开头有转场或黑帧时可以跳过
/// 一截；**跳过之后剩下的仍然整条铺满坑位**，不会只取坑位那么长。不给就
/// 从 0 开始。
///
/// [fillBySpeed] 为假时走老的「截出等长的一段、倍速 1.0」：目前只有剪映
/// 工程里的**整体替换**用它——那一层的时长本来就跟着候选走，不归这条规则管。
CandidateTrim trimFor({
  required int materialMs,
  required int slotMs,
  int? startMs,
  bool fillBySpeed = true,
}) {
  // 量不到素材时长时不硬猜：给坑位长、倍速 1.0，由导出那头按实际时长算
  if (materialMs <= 0 || slotMs <= 0) {
    return CandidateTrim(startMs: 0, durationMs: slotMs, speed: 1.0);
  }

  if (!fillBySpeed) {
    if (materialMs <= slotMs) {
      return CandidateTrim(
          startMs: 0, durationMs: materialMs, speed: materialMs / slotMs);
    }
    final latest = materialMs - slotMs;
    final from = startMs == null ? latest ~/ 2 : startMs.clamp(0, latest);
    return CandidateTrim(startMs: from, durationMs: slotMs, speed: 1.0);
  }

  // 起点最多挪到「剩下的刚好够铺满坑位」——再往后就只剩下不到一个坑位的
  // 画面，变速会从加速翻成慢放，人挪起点时不会预期这个
  final latest = materialMs > slotMs ? materialMs - slotMs : 0;
  final from = startMs == null ? 0 : startMs.clamp(0, latest);
  final usable = materialMs - from;
  return CandidateTrim(
    startMs: from,
    durationMs: usable,
    speed: usable / slotMs,
  );
}

/// 这条素材的起点能挪到哪儿——**界面拖动条的范围**。
class TrimRange {
  final int minStartMs;
  final int maxStartMs;

  const TrimRange({required this.minStartMs, required this.maxStartMs});

  /// 有没有挪的余地。素材不比坑位长时没得挪（整条都要用上还不够）
  bool get canAdjust => maxStartMs > minStartMs;
}

/// 算起点的可选范围。
///
/// 真机数据：一条 34 镜的片子里，102 条候选中有 74 条素材比坑位长 3 倍以上，
/// 最夸张的 24 倍（19 秒素材配 0.8 秒坑位）。默认整条铺满就是 24 倍快放；
/// 人可以把起点往后挪，挪到最右端时剩下的刚好一个坑位、倍速回到 1.0。
TrimRange trimRange({required int materialMs, required int slotMs}) {
  if (materialMs <= 0 || slotMs <= 0 || materialMs <= slotMs) {
    return const TrimRange(minStartMs: 0, maxStartMs: 0);
  }
  return TrimRange(minStartMs: 0, maxStartMs: materialMs - slotMs);
}

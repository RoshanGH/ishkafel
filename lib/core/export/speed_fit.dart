/// 视觉镜头替换时，候选素材要变速多少才能填满原来的坑位。
///
/// **只有镜头层（S）用它**：镜头层换的是画面，这一段的口播必须保持原样，
/// 所以候选必须变速对齐。台词语义单元层（U）是整体替换，画面和声音一起换、
/// 时长随候选，不变速（见 `docs/2026-08-07-四种替换的导出规格.md`）。
abstract final class SpeedFit {
  /// 放慢的下限。再慢就是每帧显示两遍，明显卡顿——真要用更短的素材，
  /// 冻帧比放慢好看
  static const double minFactor = 0.8;

  /// 加速的上限。丢帧在短镜头里不易察觉（本片镜头中位 1.7 秒），但 3 秒坑位
  /// 塞 10 秒素材（3.3×）就是快进了
  static const double maxFactor = 2.0;

  /// 判定边界时的容差。2.4/3.0 在二进制浮点下不是精确的 0.8，卡边界的
  /// 候选会被误判成越界
  static const double _epsilon = 1e-6;

  /// 变速倍率 = 候选时长 ÷ 坑位时长。>1 是加速，<1 是放慢
  static double factorFor({required int candidateMs, required int slotMs}) =>
      slotMs <= 0 ? 1.0 : candidateMs / slotMs;

  static bool allows(double factor) =>
      factor >= minFactor - _epsilon && factor <= maxFactor + _epsilon;

  /// 候选时长的允许区间（毫秒），用来告诉用户「该找多长的素材」
  static (int min, int max) allowedRange(int slotMs) =>
      ((slotMs * minFactor).round(), (slotMs * maxFactor).round());

  /// 给用户看的一句话；几乎不变速时返回 null——「1.01×」写出来只是噪音
  static String? describe(double factor) {
    if ((factor - 1).abs() <= 0.02) return null;
    final text = factor.toStringAsFixed(factor >= 10 ? 0 : 1);
    return factor > 1 ? '加速 $text×' : '放慢 $text×';
  }

  /// 越界的原因（含能用的时长范围）；没越界返回 null
  static String? rejectReason({required int candidateMs, required int slotMs}) {
    final factor = factorFor(candidateMs: candidateMs, slotMs: slotMs);
    if (allows(factor)) return null;
    final (min, max) = allowedRange(slotMs);
    String seconds(int ms) => (ms / 1000).toStringAsFixed(1);
    return '这一段是 ${seconds(slotMs)} 秒，候选是 ${seconds(candidateMs)} 秒，'
        '需要${describe(factor)}才能对齐——超出了 $minFactor×~$maxFactor× 的范围。'
        '请换一条 ${seconds(min)}~${seconds(max)} 秒的素材';
  }
}

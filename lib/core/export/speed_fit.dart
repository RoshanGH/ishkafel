/// 视觉镜头替换时，候选素材要变速多少才能填满原来的坑位。
///
/// **只有镜头层（S）用它**：镜头层换的是画面，这一段的口播必须保持原样，
/// 所以候选必须变速对齐。台词语义单元层（U）是整体替换，画面和声音一起换、
/// 时长随候选，不变速（见 `docs/2026-08-07-四种替换的导出规格.md`）。
abstract final class SpeedFit {
  /// 变速倍率 = 候选时长 ÷ 坑位时长。>1 是加速，<1 是放慢。
  ///
  /// **倍率不设上下限**：预览渲染的就是真实倍率的切片，用户在预览里看到
  /// 2.9× 什么样、导出来就是什么样——他看过并接受了，软件不该再拦。
  /// 原来这里有一道 0.8×~2.0× 的闸（放慢会逐帧重复、加速像快进），
  /// 那是替用户做审美判断，已拆掉；倍率仍然如实标在界面与文件名逻辑用到
  /// 的地方（见 [describe]）。
  static double factorFor({required int candidateMs, required int slotMs}) =>
      slotMs <= 0 ? 1.0 : candidateMs / slotMs;

  /// 给用户看的一句话；几乎不变速时返回 null——「1.01×」写出来只是噪音
  static String? describe(double factor) {
    if ((factor - 1).abs() <= 0.02) return null;
    final text = factor.toStringAsFixed(factor >= 10 ? 0 : 1);
    return factor > 1 ? '加速 $text×' : '放慢 $text×';
  }

  /// 这一段**实际**用多少倍率——画面和声音都问它，保证两边一致。
  ///
  /// 规则只有一条：**从 [trimStartMs] 起剩下的整条，全部变速铺满坑位**
  /// （见 [trimFor]）。跳过开头那截转场/黑帧之后剩多少，就把多少压进坑位，
  /// 不会只取坑位那么长——这正是产品要的「自动变速充满原镜头时长」。
  ///
  /// 这里曾经有一条「截过一段等长的就不再变速」的特例，那是上一版「从长
  /// 素材里截一段」的配套；现在自动截段没有了，特例跟着退休。留着它的话
  /// `trimStartMs = 0` 一样满足「剩下的够长」，于是倍率被判成 1.0，
  /// 画面又变回被剪掉一大截——真机上看到的就是这个。
  ///
  /// 画面和声音各算一份迟早会分叉，而分叉的后果是声音和画面越走越偏、
  /// 且哪儿都不报错，所以两边都只问这一个函数。
  static double effectiveFactor({
    required int? candidateMs,
    required int slotMs,
    required int? trimStartMs,
  }) {
    if (candidateMs == null) return 1.0;
    final usable = candidateMs - (trimStartMs ?? 0);
    if (usable <= 0) return 1.0;
    return factorFor(candidateMs: usable, slotMs: slotMs);
  }
}

import '../../core/ai/ai_usage.dart';

/// 首次「能进去干活」之前人等了多久。
///
/// 说「1 分 34 秒」而不是「94 秒」：后者要在脑子里除一次才知道久不久。
String? formatWaited(int? ms) {
  if (ms == null) return null;
  // 不足一秒也写 1 秒——「等待 0 秒」看着像没测出来
  final seconds = ms < 1000 ? 1 : (ms / 1000).round();
  if (seconds < 60) return '等待 $seconds 秒';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '等待 $minutes 分' : '等待 $minutes 分 $rest 秒';
}

/// 累计花费。
///
/// **算不出就说算不出**：混进一个没登记单价的模型时给出的数字必然偏低，
/// 而用户会拿它当账单看。
String formatCost(AiUsage usage) {
  final cost = usage.costYuan;
  if (cost == null) return '花费未知';
  if (cost == 0) return '¥0';
  // 一条片子的花费常在几分钱量级，两位小数会把差别抹平
  return cost < 1
      ? '¥${cost.toStringAsFixed(3)}'
      : '¥${cost.toStringAsFixed(2)}';
}

/// 逐项明细，供用户对账。
///
/// 末尾注明「按目录价折算」：火山的在线推理与语音服务都有免费额度，账号也
/// 常常是几个人共用的，这个数不等于账单上真正扣的钱。
List<String> costBreakdown(AiUsage usage) {
  final lines = <String>[
    for (final entry in usage.byModel.entries)
      () {
        final u = entry.value;
        final cost = usage.costOfModel(entry.key);
        final money = cost == null ? '单价未知' : '¥${cost.toStringAsFixed(4)}';
        // 命中缓存的部分单价只有五分之一，单列出来才看得懂钱是怎么省的
        final cached =
            u.cachedTokens == 0 ? '' : '（其中缓存命中 ${u.cachedTokens}）';
        return '${entry.key}：${u.calls} 次 · 输入 ${u.promptTokens}$cached · '
            '输出 ${u.completionTokens} · $money';
      }(),
    for (final entry in usage.byService.entries)
      () {
        final u = entry.value;
        final cost = SpeechPricing.costOf(entry.key, u.quantity);
        return '${entry.key.label}：${u.calls} 次 · '
            '${u.quantity} ${entry.key.unit} · ¥${cost.toStringAsFixed(4)}';
      }(),
  ];
  if (lines.isEmpty) return lines;
  return [...lines, '（按目录价折算，未计免费额度）'];
}

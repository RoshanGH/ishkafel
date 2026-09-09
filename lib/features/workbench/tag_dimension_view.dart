/// 把**当前**标签按「打标时的维度」分行。
///
/// 分维度那份（`TagTrace.tagsByDimension`）是打标那一刻模型的原始回答，
/// 它是过程量，**不会跟着手改走**。直接拿它显示的话，人在「改标签」里删到
/// 只剩一个，属性栏照旧摆着原来那四个——用户原话：「改完以后这里不变化」。
///
/// 所以维度只当**分组依据**，内容一律以 [tags] 为准：
/// - 每个维度只留还在 [tags] 里的；某个维度被删空了照旧留着这一行（空列表），
///   由界面写成「—」——不显示的话人会以为这个维度压根没送进去；
/// - [tags] 里维度表没有的（人手加的、词表更新过的）归到「其他」，
///   一个都不许吞：吞掉就等于人刚加的标签看不见；
/// - 维度全空（模型打的一个都没留下）时返回空 map，让界面退回一排 chips——
///   模型的答案已经荡然无存，再摆它的骨架只是噪声。
Map<String, List<String>> tagsByDimensionView(
  List<String> tags,
  Map<String, List<String>> byDimension,
) {
  if (byDimension.isEmpty) return const {};
  final live = tags.toSet();
  final placed = <String>{};
  final grouped = <String, List<String>>{};
  for (final e in byDimension.entries) {
    final kept = [
      for (final t in e.value)
        if (live.contains(t)) t,
    ];
    placed.addAll(kept);
    grouped[e.key] = kept;
  }
  if (placed.isEmpty) return const {};

  final rest = [
    for (final t in tags)
      if (!placed.contains(t)) t,
  ];
  if (rest.isNotEmpty) grouped['其他'] = rest;
  return grouped;
}

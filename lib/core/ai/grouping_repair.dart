/// 把模型返回的（可能有瑕疵的）句子分组修成一份合法分组。
///
/// 之前的做法是「校验不过就整份作废，退回每句一个单元」。真机上一次跳句就把
/// 27 句 ASR 切成了 27 个单元——而模型本来给出的是 7 个。一句一个是最差的
/// 结果：时间线上全是碎片，用户得手动合并二十几次。
///
/// 关键在于：模型输出里真正有价值的是**它想在哪里下刀**，而不是每个组的
/// 成员名单。所以只取每个组的起始句号当切点，再按切点重建连续分组——这样
/// 跳句、重复、乱序、越界全都自然消解，且结果一定是合法分组（不重不漏）。
/// 分组本来就合法时，重建结果与原样完全一致。
class GroupingRepair {
  /// 修复后的分组：连续、不重不漏、覆盖 0..total-1
  final List<List<int>> groups;

  /// 是否动过。没动过就不该向用户报「降级」——那会让人以为结果不可信
  final bool changed;

  const GroupingRepair._(this.groups, this.changed);

  static GroupingRepair of(List<List<int>> raw, {required int total}) {
    if (total <= 0) return const GroupingRepair._([], false);

    // 每个组的起始句号就是模型想下刀的位置；越界的索引直接不算数
    final cuts = <int>{};
    for (final group in raw) {
      final valid = group.where((i) => i >= 0 && i < total);
      if (valid.isEmpty) continue;
      cuts.add(valid.reduce((a, b) => a < b ? a : b));
    }
    if (cuts.isEmpty) return const GroupingRepair._([], false);

    // 开头一定要有刀，否则前面几句没人认领
    cuts.add(0);
    final starts = cuts.toList()..sort();

    final repaired = <List<int>>[
      for (var i = 0; i < starts.length; i++)
        [
          for (var s = starts[i];
              s < (i + 1 < starts.length ? starts[i + 1] : total);
              s++)
            s,
        ],
    ];

    return GroupingRepair._(
      List.unmodifiable([for (final g in repaired) List<int>.unmodifiable(g)]),
      !_same(raw, repaired),
    );
  }

  static bool _same(List<List<int>> a, List<List<int>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (var j = 0; j < a[i].length; j++) {
        if (a[i][j] != b[i][j]) return false;
      }
    }
    return true;
  }
}

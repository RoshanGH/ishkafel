/// 受限名额下的**均衡取样**。
///
/// 笛卡尔积动辄上千条，名额只有 100（或用户挑的 10）。原来的做法是取里程表
/// 的**前 N 条**——那等于「最低位转个不停，高位一动不动」：一个镜头挑了 5 条
/// 素材，导出来的十条全用其中同一条，另外四条一次都没露面
/// （2026-09-10 用户真机：「一个镜头选了5个替换，但是导出10条全是选用的
/// 其中同一个镜头」）。
///
/// 「挑差异最大的」的本意是**每个位置上的候选都尽量摊开、少重复**：5 个候选
/// 出 10 条，就该各出现两次。所以取样按位独立地轮转：每一位把自己的候选
/// 洗一遍用一遍，用完再洗一遍，天然保证「各候选出现次数最多差一次」。
///
/// 每一位、每一轮用的都是**不同的**排列，两位候选数相同也不会齐步走——
/// 否则 5×5 挑 25 条只会出现 5 种搭配，位与位之间的差异就白挑了。
library;

/// 给 [optionCounts] 描述的每一位，取 [count] 组下标。
///
/// 返回 [count] 个向量，第 j 位的值落在 `[0, optionCounts[j])`；
/// 每一位上各取值的出现次数最多相差 1。不用随机数——同一个方案取两次
/// 给出不同结果的话，用户会以为自己看错了。
List<List<int>> balancedVectors(List<int> optionCounts, int count) {
  if (count <= 0) return const [];
  final columns = [
    for (var j = 0; j < optionCounts.length; j++)
      _column(optionCounts[j], count, j),
  ];
  return List.unmodifiable([
    for (var k = 0; k < count; k++)
      List<int>.unmodifiable([for (final column in columns) column[k]]),
  ]);
}

/// 一位上取 [count] 个下标：整轮整轮地洗，洗到够
List<int> _column(int n, int count, int slot) {
  if (n <= 1) return List<int>.filled(count, 0);
  final out = <int>[];
  for (var round = 0; out.length < count; round++) {
    out.addAll(_shuffled(n, slot * 7919 + round * 104729 + 1));
  }
  return out.sublist(0, count);
}

/// 定死种子的洗牌。用 Fisher-Yates + 一个小 LCG，不引第三方随机数——
/// 要的是「同样输入永远同样输出」，不是统计意义上的随机
List<int> _shuffled(int n, int seed) {
  final out = [for (var i = 0; i < n; i++) i];
  var state = seed & 0x7fffffff;
  int next() {
    // Numerical Recipes 的 LCG 参数，32 位内取模
    state = (state * 1664525 + 1013904223) & 0xffffffff;
    return state >> 8;
  }

  for (var i = n - 1; i > 0; i--) {
    final j = next() % (i + 1);
    final tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

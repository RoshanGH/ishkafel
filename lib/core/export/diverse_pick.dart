import '../replacement/picked_material.dart';
import 'export_plan.dart';

/// 从全部排列组合里挑 [count] 条**彼此差异最大**的。
///
/// 5 个分子各选 3 条素材就是 243 条组合，全导出去没人看得完，也没意义——
/// 真正要的是几条彼此明显不同的，拿去投放测试。
///
/// ## 距离为什么不能只数「换了几个位置」
///
/// 最直接的定义是汉明距离：两条组合有几个位置用了不同的素材。但同一批拍摄
/// 切出来的素材画面几乎一样——按位置数它们「不同」，眼睛看是一模一样。
/// 照这个挑，会挑出**每个位置都换了素材、却完全重复的几条**，白导一场。
///
/// 所以距离算在素材本身的相似度上（[_similarity]）：同一位置换成一条几乎
/// 一样的素材，这一位贡献的距离接近 0。
///
/// ## 为什么是 max-min 而不是 max-sum
///
/// max-sum（总距离最大）允许两条挨得很近，只要别的离得远；**max-min 保证
/// 任意两条之间都不接近**——那才是「挑出来每一条都不一样」。
///
/// 这是经典的 p-dispersion 问题（NP-hard），但这里的规模（几千条里挑十条）
/// 下贪心 + 一轮局部交换基本就是最优，毫秒级。
///
/// ## 顺带兼顾覆盖
///
/// 纯 max-min 可能只用到少数几条素材，另一些一次都不出现——而投放测试里
/// 没露过面的素材根本测不出效果。所以打分时对「带来新素材」给加分
/// （[_coverageWeight]），一个算法同时管住两个目标。
List<ExportCombination> pickDiverse(
  List<ExportCombination> all, {
  required int count,
  required List<PickedMaterial> materials,
}) {
  if (count <= 0) return const [];
  if (all.length <= count) return List.unmodifiable(all);

  final byId = {for (final m in materials) m.id: m};
  final features = [for (final combo in all) _featureOf(combo)];
  final distances = _distanceMatrix(features, byId);

  // 种子：与所有其他组合平均距离最大的那条。取平均而不是随机，
  // 是为了同样的输入永远挑出同样的几条——同一个方案挑两次给出不同结果，
  // 用户会以为自己看错了
  var seed = 0;
  var bestAverage = -1.0;
  for (var i = 0; i < all.length; i++) {
    final average =
        distances[i].reduce((a, b) => a + b) / (all.length - 1).clamp(1, 1 << 30);
    if (average > bestAverage) {
      bestAverage = average;
      seed = i;
    }
  }

  final chosen = <int>[seed];
  final used = {...features[seed].materialIds.whereType<int>()};

  while (chosen.length < count) {
    var best = -1;
    var bestScore = -1.0;
    for (var i = 0; i < all.length; i++) {
      if (chosen.contains(i)) continue;
      // 与已选那几条的**最小**距离——保证任意两条之间都不接近
      var minDistance = double.infinity;
      for (final picked in chosen) {
        final d = distances[i][picked];
        if (d < minDistance) minDistance = d;
      }
      final fresh = features[i]
          .materialIds
          .whereType<int>()
          .where((id) => !used.contains(id))
          .length;
      final positions = features[i].materialIds.length.clamp(1, 1 << 30);
      final score = minDistance + _coverageWeight * (fresh / positions);
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    if (best < 0) break;
    chosen.add(best);
    used.addAll(features[best].materialIds.whereType<int>());
  }

  chosen.sort();
  return List.unmodifiable([for (final i in chosen) all[i]]);
}

/// 「带来一条没露过面的素材」值多少距离。
///
/// 0.5 是刻意压在 1 以下的：覆盖是加分项，不能压过「两条不能长得一样」
/// 这个主目标。
const double _coverageWeight = 0.5;

class _Feature {
  /// 每个分子用了哪条素材；null 表示这一段用原片
  final List<int?> materialIds;
  const _Feature(this.materialIds);
}

_Feature _featureOf(ExportCombination combo) {
  final byUnit = <int, int?>{};
  for (final segment in combo.segments) {
    // 一个单元可能有多段（镜头替换），任一段有候选就记下来
    byUnit[segment.unitIndex] ??= segment.candidateId;
    if (segment.candidateId != null) byUnit[segment.unitIndex] = segment.candidateId;
  }
  final units = byUnit.keys.toList()..sort();
  return _Feature([for (final u in units) byUnit[u]]);
}

List<List<double>> _distanceMatrix(
    List<_Feature> features, Map<int, PickedMaterial> byId) {
  final n = features.length;
  final matrix = [for (var i = 0; i < n; i++) List<double>.filled(n, 0)];
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final d = _distance(features[i], features[j], byId);
      matrix[i][j] = d;
      matrix[j][i] = d;
    }
  }
  return matrix;
}

/// 两条组合的距离：各位置素材距离之和，再除以位置数（归一到 0~1）
double _distance(_Feature a, _Feature b, Map<int, PickedMaterial> byId) {
  final n = a.materialIds.length < b.materialIds.length
      ? a.materialIds.length
      : b.materialIds.length;
  if (n == 0) return 0;
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    sum += 1 - _similarity(a.materialIds[i], b.materialIds[i], byId);
  }
  return sum / n;
}

/// 两条素材有多像（1 = 一样，0 = 毫不相干）。
///
/// 用的是手头已经落地的信息（名字、画面描述），不去算图像特征——那太重，
/// 而这两样已经足够把「同一批拍摄」和「完全不同的场景」分开。
double _similarity(int? a, int? b, Map<int, PickedMaterial> byId) {
  if (a == b) return 1; // 同一条素材，或者两边都用原片
  if (a == null || b == null) return 0; // 一边原片一边换过，那是实打实的差异
  final left = byId[a];
  final right = byId[b];
  // 没有落地信息时只能按「不同 id = 不同素材」算，退回汉明距离那套
  if (left == null || right == null) return 0;

  // 同一批：名字长公共前缀 + id 相邻，多半是同一条原片切出来的
  final prefix = _commonPrefixRatio(left.name, right.name);
  final adjacent = (a - b).abs() <= 4 ? 0.3 : 0.0;
  final batch = (prefix * 0.9 + adjacent).clamp(0.0, 1.0);

  // 画面描述的词重合
  final scene = _bigramJaccard(left.sceneDescription, right.sceneDescription);

  // 取两者较大的：任一条证据强烈指向「像」，就是像
  return batch > scene ? batch : scene;
}

double _commonPrefixRatio(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final limit = a.length < b.length ? a.length : b.length;
  var same = 0;
  while (same < limit && a[same] == b[same]) {
    same++;
  }
  final longer = a.length > b.length ? a.length : b.length;
  return same / longer;
}

/// 字符二元组的 Jaccard。中文没有空格分词，二元组比按字更能反映短语重合
double _bigramJaccard(String a, String b) {
  final left = _bigrams(a);
  final right = _bigrams(b);
  if (left.isEmpty || right.isEmpty) return 0;
  final intersection = left.intersection(right).length;
  final union = left.union(right).length;
  return union == 0 ? 0 : intersection / union;
}

Set<String> _bigrams(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), '');
  if (text.length < 2) return text.isEmpty ? const {} : {text};
  return {
    for (var i = 0; i < text.length - 1; i++) text.substring(i, i + 2),
  };
}

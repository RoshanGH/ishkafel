import '../replacement/picked_material.dart';
import 'export_plan.dart';

/// 从全部排列组合里挑 [count] 条**重复度最低**的。
///
/// 5 个分子各选 3 条素材就是 243 条组合，全导出去没人看得完，也没意义——
/// 真正要的是几条彼此明显不同的，拿去投放测试。
///
/// ## 第一条准则：每个位置上的候选都要摊开
///
/// 「挑差异最大的」首先是**少重复**：一个位置挑了 5 条素材、要出 10 条片子，
/// 就该 5 条各出现两次，而不是十条全用其中一条
/// （2026-09-10 用户真机：「一个镜头选了5个替换，但是导出10条全是选用的
/// 其中同一个镜头……任何一个替换的位置都尽量不重复」）。
///
/// 所以每个位置先算一份**配额**：这个位置有 n 条候选、要出 k 条片子，
/// 谁都不许超过 ⌈k/n⌉ 次（5 条候选出 10 条 = 每条最多 2 次，也就正好 2 次）。
/// 配额之内再比「已经用过几次」，越少越先挑。
///
/// 光比「用过几次」不够：两个位置的重复次数可以互相抵，贪心走到最后常常
/// 剩下「这一位重复一次 / 那一位重复一次」的两难，结果某条素材用了三次、
/// 另一条只用了一次。配额是硬的，把这种偏斜直接堵死。
///
/// 「相似度」不能替代这一条：同一批拍摄切出来的 5 条素材彼此相似度接近 1，
/// 按距离算「换了等于没换」，于是算法索性一条用到底——那正是用户看到的
/// 结果。看着像，不是重复用同一条的理由；人既然挑了 5 条，就得 5 条都露面。
///
/// ## 第二条准则：两两之间不要撞在一起
///
/// 重复度打平时才比距离，取**与已选各条的最小距离最大**的那条（max-min，
/// 不是 max-sum）——max-sum 允许两条挨得很近，只要别的离得远。
///
/// 距离算在素材本身的相似度上（[_similarity]）而不是「有几个位置换了素材」：
/// 同一批拍摄的两条素材换来换去，眼睛看是一模一样。但换过总比没换强，
/// 所以换了一条不同的素材至少记 [_differentFloor] 的距离——这一位保证了
/// 「同样均衡的两种排法里，优先选搭配没出现过的」。
///
/// ## 位置是**镜头**级的
///
/// 一个台词语义单元里可以有好几个视觉镜头各自替换。按单元合并的话，
/// 前面那几镜换没换完全看不见（旧实现只留了最后一镜），于是那几镜的候选
/// 就永远轮不上。
List<ExportCombination> pickDiverse(
  List<ExportCombination> all, {
  required int count,
  required List<PickedMaterial> materials,
}) {
  if (count <= 0) return const [];
  if (all.length <= count) return List.unmodifiable(all);

  final byId = {for (final m in materials) m.id: m};
  final positions = _varyingPositions(all);
  final features = [for (final combo in all) _featureOf(combo, positions)];
  final distances = _distanceMatrix(features, byId);

  // 种子：与所有其他组合平均距离最大的那条。取平均而不是随机，
  // 是为了同样的输入永远挑出同样的几条——同一个方案挑两次给出不同结果，
  // 用户会以为自己看错了
  var seed = 0;
  var bestAverage = -1.0;
  for (var i = 0; i < all.length; i++) {
    final average = distances[i].reduce((a, b) => a + b) /
        (all.length - 1).clamp(1, 1 << 30);
    if (average > bestAverage) {
      bestAverage = average;
      seed = i;
    }
  }

  final chosen = <int>[seed];
  // 每个位置上，各条素材已经被用了几次
  final usage = [for (final _ in positions) <int?, int>{}];
  // 每个位置上，一条素材最多出现几次
  final caps = _capsOf(features, positions.length, count);
  void take(int i) {
    for (var p = 0; p < positions.length; p++) {
      final id = features[i].materialIds[p];
      usage[p][id] = (usage[p][id] ?? 0) + 1;
    }
  }

  take(seed);

  while (chosen.length < count) {
    var best = -1;
    var bestOver = 1 << 30;
    var bestRepeats = 1 << 30;
    var bestDistance = -1.0;
    for (var i = 0; i < all.length; i++) {
      if (chosen.contains(i)) continue;
      // 这一条会带来多少重复：每个位置上它要用的那条素材已经用过几次；
      // 以及它在几个位置上会突破配额（正常情况下是 0，走投无路时才挑最少的）
      var repeats = 0;
      var over = 0;
      for (var p = 0; p < positions.length; p++) {
        final used = usage[p][features[i].materialIds[p]] ?? 0;
        repeats += used;
        if (used + 1 > caps[p]) over++;
      }
      if (over > bestOver) continue;
      if (over == bestOver && repeats > bestRepeats) continue;
      // 与已选那几条的**最小**距离——保证任意两条之间都不接近
      var minDistance = double.infinity;
      for (final picked in chosen) {
        final d = distances[i][picked];
        if (d < minDistance) minDistance = d;
      }
      final better = over < bestOver ||
          repeats < bestRepeats ||
          minDistance > bestDistance;
      if (better) {
        bestOver = over;
        bestRepeats = repeats;
        bestDistance = minDistance;
        best = i;
      }
    }
    if (best < 0) break;
    chosen.add(best);
    take(best);
  }

  // 贪心会把自己走进死角：前面几步随手用掉的搭配，到最后剩下的每一条都
  // 超配额，于是某条素材出现三次、另一条只出现一次。收尾做一轮局部交换，
  // 把超出配额的那几条换掉
  _rebalance(
    chosen: chosen,
    features: features,
    usage: usage,
    caps: caps,
    total: all.length,
  );

  chosen.sort();
  return List.unmodifiable([for (final i in chosen) all[i]]);
}

/// 收尾的局部交换：只要还有位置超配额，就试着把一条已选的换成一条没选的，
/// 换到超额总量降不下去为止。
///
/// 贪心 + 一轮局部交换是 p-dispersion 这类问题的常规做法：贪心快但会
/// 走进死角，交换把死角里的那几条捞回来。规模就几十条，毫秒级
void _rebalance({
  required List<int> chosen,
  required List<_Feature> features,
  required List<Map<int?, int>> usage,
  required List<int> caps,
  required int total,
}) {
  void apply(int index, int delta) {
    for (var p = 0; p < usage.length; p++) {
      final id = features[index].materialIds[p];
      final next = (usage[p][id] ?? 0) + delta;
      usage[p][id] = next;
    }
  }

  var excess = _excessOf(usage, caps);
  // 每一轮至少把超额降 1，降到 0 就收工；上限只是防死循环
  for (var round = 0; excess > 0 && round < chosen.length * 2; round++) {
    var swapped = false;
    for (var slot = 0; slot < chosen.length && !swapped; slot++) {
      final out = chosen[slot];
      apply(out, -1);
      for (var candidate = 0; candidate < total; candidate++) {
        if (chosen.contains(candidate)) continue;
        apply(candidate, 1);
        final after = _excessOf(usage, caps);
        if (after < excess) {
          chosen[slot] = candidate;
          excess = after;
          swapped = true;
          break;
        }
        apply(candidate, -1);
      }
      if (!swapped) apply(out, 1);
    }
    if (!swapped) break; // 换不动了，剩下的超额是排法本身给不出来的
  }
}

/// 一共超出配额多少次
int _excessOf(List<Map<int?, int>> usage, List<int> caps) {
  var sum = 0;
  for (var p = 0; p < usage.length; p++) {
    for (final used in usage[p].values) {
      if (used > caps[p]) sum += used - caps[p];
    }
  }
  return sum;
}

/// 每个位置上一条素材最多出现几次：这一位有 n 条候选、要出 k 条片子，
/// 就是 ⌈k/n⌉。**这是硬的**——「挑 10 条」里某条素材出现 3 次而另一条
/// 只出现 1 次，就是用户说的那种重复
List<int> _capsOf(List<_Feature> features, int positions, int count) => [
      for (var p = 0; p < positions; p++)
        () {
          final distinct = <int?>{
            for (final feature in features) feature.materialIds[p],
          }.length;
          return distinct == 0 ? count : (count + distinct - 1) ~/ distinct;
        }(),
    ];

/// 换了一条不同的素材，至少值这么多距离——哪怕它跟原来那条长得一模一样。
///
/// 压得很低（相对于「完全不同」的 1）：它只用来在重复度打平时，
/// 把「搭配从没出现过」排在「又是那对组合」前面
const double _differentFloor = 0.15;

/// 哪些位置真的在变。恒定的位置（整段都用原片、或者只有一条候选）
/// 参与进来只会把距离摊薄，也没有可挑的余地
List<String> _varyingPositions(List<ExportCombination> all) {
  final values = <String, Set<int?>>{};
  final order = <String>[];
  for (final combo in all) {
    for (final segment in combo.segments) {
      final key = _positionKey(segment);
      final seen = values[key];
      if (seen == null) {
        values[key] = {segment.candidateId};
        order.add(key);
      } else {
        seen.add(segment.candidateId);
      }
    }
  }
  return [
    for (final key in order)
      if ((values[key]?.length ?? 0) > 1) key,
  ];
}

String _positionKey(ExportSegment segment) =>
    '${segment.unitIndex}:${segment.shotIndex}';

class _Feature {
  /// 每个**可变位置**用了哪条素材；null 表示这一段用原片
  final List<int?> materialIds;
  const _Feature(this.materialIds);
}

_Feature _featureOf(ExportCombination combo, List<String> positions) {
  final byPosition = <String, int?>{};
  for (final segment in combo.segments) {
    byPosition[_positionKey(segment)] = segment.candidateId;
  }
  return _Feature([for (final key in positions) byPosition[key]]);
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
    final left = a.materialIds[i];
    final right = b.materialIds[i];
    if (left == right) continue; // 同一条素材，这一位没有任何差异
    final apart = 1 - _similarity(left, right, byId);
    // 换了一条不同的素材，至少记一点距离——哪怕它跟原来那条长得一样
    sum += _differentFloor + apart * (1 - _differentFloor);
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

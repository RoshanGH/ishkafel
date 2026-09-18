import 'package:collection/collection.dart';

import '../models/semantic_unit.dart';

/// 这两份切分**除了来源戳之外**还有别的不一样吗。
///
/// 为什么要单独有这么一条判据：`editedBy` 确实是数据的一部分（它参与
/// `SemanticUnit` / `Shot` 的 `==`，两个模型的序列化往返测试靠的就是深度
/// 相等），但它回答的是「这一处是**谁**定的」，不是「这一处**是什么**」。
/// 判「这一次到底改没改东西」时必须把它排除掉——否则 Agent 每写一次、
/// 盖一次戳，界面那道「变了没有」的守卫就判「变了」，于是落一次盘、
/// 记一笔**人名下的空改动**，而人一根手指都没动（2026-09-18 真机受控
/// 复现：Agent 写一次，日志 +2）。
///
/// **按 `toJson()` 比，不逐字段列**：这样以后给单元或镜头加字段，
/// 默认落在「算改动」那一边——宁可多写一次盘，不能静默丢掉人的改动。
bool segmentationChanged(
        List<SemanticUnit> before, List<SemanticUnit> after) =>
    !const DeepCollectionEquality()
        .equals(_withoutStamps(before), _withoutStamps(after));

List<Map<String, dynamic>> _withoutStamps(List<SemanticUnit> units) => [
      for (final u in units) _stripStamp(u.toJson()),
    ];

/// 去掉这一层的 `editedBy`，并对嵌在里面的镜头逐个去掉。
///
/// 只认 `editedBy` 这一个键——别用「凡是 Map 就递归」的写法，
/// `trace`、`baseSentences` 那些也是嵌套结构，它们的变化是真改动
Map<String, dynamic> _stripStamp(Map<String, dynamic> json) => {
      for (final e in json.entries)
        if (e.key != 'editedBy')
          e.key: e.key == 'shots' && e.value is List
              ? [
                  for (final s in e.value as List)
                    s is Map<String, dynamic> ? _stripStamp(s) : s,
                ]
              : e.value,
    };

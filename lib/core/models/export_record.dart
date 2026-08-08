import 'package:flutter/foundation.dart';

import '../log/app_log.dart';

/// 一次导出留下的记录：**哪天、导了几条、成了几条、在哪个目录**。
///
/// 为什么要有它：这个产品的对象是「项目」——一条原片放在那儿，今天挑两个
/// 组合导出去，明天换两个再导。项目本身没有「完成」这回事，**导出才是那件
/// 有始有终的事**。用户原话：「它应该就是一个项目放在那，能不停的导出，
/// 然后明天我再换两个再导出……只是说导出的这些东西，它会有个任务，就是在
/// 哪天导出了哪个项目导出了几个视频在哪里。」
///
/// 此前既没有这份记录，任务状态里那个 `exported` 也**从来没有被设置过**——
/// 于是「编辑中」永远不会结束、「已完成」筛选永远是空的。
@immutable
class ExportRecord {
  final DateTime at;

  /// 这一批计划导几条
  final int total;

  /// 真正导成了几条。小于 [total] 时说明有失败的
  final int succeeded;

  /// 导到哪个目录去了。用户要能照着它去找片子
  final String outputDir;

  const ExportRecord({
    required this.at,
    required this.total,
    required this.succeeded,
    required this.outputDir,
  });

  bool get allSucceeded => succeeded == total;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'total': total,
        'succeeded': succeeded,
        'outputDir': outputDir,
      };

  /// 宽松解析：畸形的那一条跳过，不牵连整份任务
  static ExportRecord? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    final outputDir = raw['outputDir'];
    if (at == null || outputDir is! String) {
      AppLog.warn('导出记录字段缺失，跳过这一条');
      return null;
    }
    final total = raw['total'];
    final succeeded = raw['succeeded'];
    return ExportRecord(
      at: at,
      total: total is int ? total : 0,
      succeeded: succeeded is int ? succeeded : 0,
      outputDir: outputDir,
    );
  }

  static List<ExportRecord> parseList(Object? raw) {
    if (raw is! List) return const [];
    return List.unmodifiable([
      for (final item in raw) ?tryFromJson(item),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is ExportRecord &&
      other.at == at &&
      other.total == total &&
      other.succeeded == succeeded &&
      other.outputDir == outputDir;

  @override
  int get hashCode => Object.hash(at, total, succeeded, outputDir);
}

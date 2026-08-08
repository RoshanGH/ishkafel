import '../../core/models/export_record.dart';
import '../../core/models/renew_task.dart';

/// 任务卡上的一行「下一步做什么」。
///
/// 状态徽标只说「现在是什么状态」，用户还得自己翻译成动作。四个状态里有两个
/// 该点进去、一个该等着、一个点了会被拒绝——不写清楚，用户只能靠试。
///
/// 优先级：源文件缺失 > 分析失败 > 常规状态。前两者是前提被破坏，
/// 这时引导用户去做常规动作只会让他撞墙。
String taskCardHint(RenewTask task, {bool sourceMissing = false}) {
  if (sourceMissing) return '源文件已不在原位，放回后才能继续';
  if (task.analysisError != null) return '分析未完成，可在右键菜单里「重新分析」';

  final scale = _scale(task);
  return switch (task.status) {
    RenewTaskStatus.analyzing => '正在自动分析，完成后会自动进入下一步',
    // 导过一次不代表这个项目结束了——原片放在那儿，换一批素材还能再导
    RenewTaskStatus.ready => task.exports.isEmpty
        ? '$scale点击进入工作台，调整切分并替换素材'
        : '$scale${lastExportSummary(task.exports)}，可继续换素材再导',
  };
}

/// 最近一次导出：「8月8日导出 6 条」。没导过时返回空串
String lastExportSummary(List<ExportRecord> exports) {
  if (exports.isEmpty) return '';
  final last = exports.last;
  final failed = last.total - last.succeeded;
  final tail = failed > 0 ? '（$failed 条失败）' : '';
  return '${last.at.month}月${last.at.day}日导出 ${last.succeeded} 条$tail';
}

/// 「共 N 个台词语义单元 · 」；还没有切分结果时给空串——写「共 0 个」
/// 会被读成分析出来是空的
String _scale(RenewTask task) {
  final count = task.units?.length ?? 0;
  return count == 0 ? '' : '共 $count 个台词语义单元 · ';
}

import 'dart:async';

import '../../core/analysis/pending_tagging.dart';
import '../../core/analysis/tagging_service.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/storage/task_repository.dart';

/// 补标签补到哪儿了。**界面自己显示**——这是软件在干活，不是 Agent，
/// 不许占 Agent 那条播报通道（占了人就分不清是谁在动手）
class TaggingProgress {
  final String taskId;
  final String taskName;
  final int done;
  final int total;
  const TaggingProgress(this.taskId, this.taskName, this.done, this.total);
}

/// **把上次没打完的标补上。**
///
/// 打标是切分落库之后转入后台跑的（让人 26 秒就能进去看切分，不用等占七成
/// 时长的打标）。这个优化本身是对的，错在它只做了乐观路径：app 一关——
/// 崩溃、手动退出、升级重启、睡眠——打标就**永久丢了**。任务状态已经是
/// ready，看起来一切正常，没有任何地方记得它还欠着。
///
/// 真机上丢过一次：一条刚上传的片子 35 个镜头一个标签、一句描述都没有，
/// 而界面上什么都不说。人看到的是「上传完视频进去发现没标签」，找不到
/// 原因，那一趟的钱也白花了。
///
/// 所以：**每次启动扫一遍，欠的接着打**。这不是替人做决定——打标本来就是
/// 他上传视频时同意的那趟分析的一部分，只是没跑完。
class TaggingResumer {
  final TaskRepository repository;
  final TaggingService tagging;

  /// 一次只补一条。打标要走云端推理、要花钱，几条并排跑既慢又难说清进度
  bool _running = false;

  TaggingResumer({required this.repository, required this.tagging});

  bool get running => _running;

  /// 扫一遍，把欠打标的补上。[onProgress] 给界面显示用；
  /// [shouldStop] 让调用方随时叫停（页面销毁、人要关软件）
  Future<int> resumeAll({
    void Function(TaggingProgress? progress)? onProgress,
    bool Function()? shouldStop,
  }) async {
    if (_running) return 0;
    _running = true;
    var fixed = 0;
    try {
      final tasks = await repository.findAll();
      final pending = tasks.where(needsTagging).toList();
      if (pending.isEmpty) return 0;
      AppLog.info('有 ${pending.length} 条任务的标签没打完，接着打');
      for (final task in pending) {
        if (shouldStop?.call() ?? false) break;
        if (await _resumeOne(task, onProgress, shouldStop)) fixed++;
      }
    } catch (e) {
      // 补标签失败不该拦住人用软件——它是补救，不是主流程
      AppLog.warn('补标签失败：$e');
    } finally {
      _running = false;
      onProgress?.call(null);
    }
    return fixed;
  }

  Future<bool> _resumeOne(
    RenewTask task,
    void Function(TaggingProgress?)? onProgress,
    bool Function()? shouldStop,
  ) async {
    final units = task.units;
    if (units == null) return false;
    final want = unitsPendingTagging(task);
    if (want.isEmpty) return false;
    onProgress?.call(TaggingProgress(task.id, task.name, 0, want.length));
    try {
      final tagged = await tagging.tag(task, units, only: want,
          onProgress: (p) {
        if (p.total != null && p.done != null) {
          onProgress?.call(
              TaggingProgress(task.id, task.name, p.done!, p.total!));
        }
      });
      if (shouldStop?.call() ?? false) return false;
      // **重读再写**：补标签期间人可能正在工作台里改这条任务，
      // 拿手上这份旧的整个覆盖回去，会把他刚做的编辑抹掉
      final fresh = await repository.findById(task.id);
      if (fresh == null) return false;
      final merged = [
        for (var i = 0; i < (fresh.units?.length ?? 0); i++)
          if (want.contains(i) && i < tagged.length)
            // 只把补上的标签搬过去，边界以他现在这份为准
            fresh.units![i].copyWith(
              tags: tagged[i].tags,
              trace: tagged[i].trace,
              shots: fresh.units![i].shots.length == tagged[i].shots.length
                  ? tagged[i].shots
                  : fresh.units![i].shots,
            )
          else
            fresh.units![i],
      ];
      await repository.save(
          fresh.copyWith(units: merged, updatedAt: DateTime.now()));
      AppLog.info('补完「${task.name}」的 ${want.length} 个单元的标签');
      return true;
    } catch (e) {
      AppLog.warn('补「${task.name}」的标签没成：$e');
      return false;
    }
  }
}

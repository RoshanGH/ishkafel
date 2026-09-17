import 'dart:async';
import 'dart:io';

import '../../core/analysis/pending_tagging.dart';
import '../../core/analysis/tag_merge.dart';
import '../../core/analysis/tagging_service.dart';
import '../../core/log/app_log.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/unit_uid.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_repository.dart';
import 'gui_task_mutation.dart';

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

  /// 改动日志落在哪儿。补上的标签也要记一笔——不然人下次打开看到多出来的
  /// 标签，没有任何地方说得清它们是哪来的
  final Directory dataDir;

  /// 一次只补一条。打标要走云端推理、要花钱，几条并排跑既慢又难说清进度
  bool _running = false;

  TaggingResumer({
    required this.repository,
    required this.tagging,
    required this.dataDir,
  });

  /// 这一笔算谁的：**人这一侧**。
  ///
  /// 它不是 Agent 让它跑的，是人打开这个 app 带出来的——「软件在干活，
  /// 不是 Agent」（同 `TaggingProgress` 那条注释）。具体是软件自己动的手，
  /// 由每一笔的 `note` 说清楚。
  TaskMutation get _mutation => humanMutation(
      repo: repository, dataDir: dataDir, actor: actorTaskList);

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
      // 扫描结果要说出来：查不出问题时，「有没有扫到」是第一个要排除的
      AppLog.info('补标签：扫了 ${tasks.length} 条任务，'
          '${pending.length} 条欠着'
          '${pending.isEmpty ? '' : '（${pending.map((t) => t.name).join('、')}）'}');
      if (pending.isEmpty) return 0;
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
      // **配对按身份，不是按下标**。写盘时重读回来的那份正是他改过的：
      // 加过单元、拖过顺序，下标早就不是发起打标时那一套了。按下标写回，
      // 标签会结结实实糊到别人身上，而且哪儿都不报错——2026-09-16 真机：
      // 新加的空单元拖到第一位，还没做任何操作就凭空带上了隔壁那个的标签。
      //
      // 身份发出去就不变（见 `unit_uid.dart`），产品负责人当初立这条规矩
      // 说的就是这件事：「它这个编号下的所有数据都是跟着这个编号走。」
      final taggedByUid = {
        for (final u in tagged)
          if (isUnitUid(u.uid)) u.uid: u,
      };
      final wantUids = {
        for (final i in want)
          if (i < units.length && isUnitUid(units[i].uid)) units[i].uid,
      };
      // 打标是分钟级的云端活儿，已经在上面做完了——edit 里只剩「把标签搬到
      // 当前这份单元上」这一步纯变换，被重跑一次也不会重打一遍标
      final done = await _mutation.apply(
        taskId: task.id,
        op: 'units.tag.resume',
        note: '软件补上了上次没打完的标签（打标是上传那趟分析的一部分，没跑完）',
        edit: (fresh) {
          final freshUnits = fresh.units;
          // units 本来是 null（没分析过）绝不能悄悄变成 []——那是另一个事实
          if (freshUnits == null) {
            return TaskEdit(
              task: fresh,
              before: {'unitCount': 0},
              after: {'unitCount': 0, 'note': 'units 是 null，无标签可补'},
            );
          }
          final merged = [
            for (final unit in freshUnits)
              _withNewTags(unit,
                  wantUids.contains(unit.uid) ? taggedByUid[unit.uid] : null),
          ];
          return TaskEdit(
            task: fresh.copyWith(units: merged),
            before: {
              'untagged': [
                for (final u in freshUnits)
                  if (wantUids.contains(u.uid))
                    {'unitUid': u.uid, 'transcript': u.transcript},
              ],
            },
            after: {
              // 真正变了标签的那几个。判据跟 mergeTagsInto 用的是同一个
              // （tag_merge.dart 导出的 unitTagsChanged）：只比单元级 tags
              // 会漏掉「单元标签没动、某一镜的标签是这次填上的」那种
              'taggedUnits': [
                for (var i = 0; i < freshUnits.length; i++)
                  if (unitTagsChanged(freshUnits[i], merged[i]))
                    {'unitUid': merged[i].uid, 'tags': merged[i].tags},
              ],
            },
          );
        },
      );
      if (done == null) {
        AppLog.warn('补「${task.name}」的标签落库时这条任务已经被删了，结果丢弃。');
        return false;
      }
      AppLog.info('补完「${task.name}」的 ${want.length} 个单元的标签');
      return true;
    } catch (e) {
      AppLog.warn('补「${task.name}」的标签没成：$e');
      return false;
    }
  }
}

/// 把补出来的标签搬到 [unit] 身上。**边界以他现在这份为准**——
/// 补标签期间他可能动过切分，镜头数对不上就不动镜头那一层。
/// [tagged] 为 null（不在这一轮、或身份对不上）时原样返回
SemanticUnit _withNewTags(SemanticUnit unit, SemanticUnit? tagged) {
  if (tagged == null) return unit;
  return unit.copyWith(
    tags: tagged.tags,
    trace: tagged.trace,
    shots: unit.shots.length == tagged.shots.length ? tagged.shots : unit.shots,
  );
}

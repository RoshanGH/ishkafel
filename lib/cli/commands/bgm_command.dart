import 'dart:io';

import 'package:collection/collection.dart';

import '../../core/audio/bgm_plan.dart';
import '../../core/audio/bgm_range.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_seq.dart';
import '../agent_lock_holder.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import '../cli_output.dart';

/// `ishkafel bgm <任务> [--from 0 --to 2 --materials 7,8] [--remove] [--volume 0.3]`
///
/// 给一段台词语义单元铺配乐。界面上人能铺、能改区间、能删、能调音量，
/// **整套 Agent 一个都做不了**——而配乐是进成片的东西，不是装饰。
/// （脚本成片那条线有 `script bgm-candidates` / `script apply bgm`，
/// 替换裂变一直没有。）
///
/// 一段可以选好几首**互为备选**：导出多条时按变体轮流用，不是叠着放。
Future<int> runBgmCommand({
  required List<String> rest,
  required Directory dataDir,
  String? fromUnit,
  String? toUnit,
  String? materialIds,
  String? volume,
  bool remove = false,
  String? holder,

  /// 可视模式：配乐色带上当场看见铺了哪一段
  bool? visual,
  required Future<BgmMaterial?> Function(int id) fetchMaterial,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel bgm <任务 id> --from 0 --to 2 --materials 7,8\n'
        '  --remove 删掉从 --from 开始的那一段；--volume 调音量（0~1）\n'
        '  不给参数就是看现状。有哪些曲子：ishkafel script bgm-candidates');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final units = task.units ?? const [];
  if (units.isEmpty) {
    sink.writeln('「${task.name}」还没有台词语义单元——先跑 ishkafel analyze');
    return exitBadUsage;
  }

  // 只看现状
  if (fromUnit == null && !remove) {
    emitJson({
      'taskId': task.id,
      'segments': [
        for (final s in task.bgm.segments)
          {
            'fromUnit': s.startUnit,
            'toUnit': s.endUnit,
            'volume': s.volume,
            'materials': [
              for (final m in s.materials) {'id': m.id, 'name': m.name},
            ],
          },
      ],
      'hint': '铺配乐：ishkafel bgm <任务> --from 0 --to 2 --materials 7,8。'
          '有哪些曲子用 ishkafel script bgm-candidates 看。'
          '一段选好几首是**互为备选**——导出多条时轮流用，不是叠着放',
    }, out: out);
    return 0;
  }

  final from = int.tryParse((fromUnit ?? '').trim());
  if (from == null) {
    sink.writeln('--from 要给单元下标（从 0 起）');
    return exitBadUsage;
  }
  final to = int.tryParse((toUnit ?? '').trim()) ?? from;
  // 越界要点名：静默夹回去的话，人以为铺到了第 3 段、其实只铺了 2 段
  final bad = [from, to].where((i) => i < 0 || i >= units.length).toList();
  if (bad.isNotEmpty) {
    sink.writeln('这些单元不存在：${bad.join('、')}（这条片子一共 ${units.length} 个）');
    return exitBadUsage;
  }

  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? agentLockHolder,
  );
  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  final who = holder ?? agentLockHolder;
  if (!lock.acquire(who)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，先等它');
    return exitLocked;
  }
  try {
    // 取素材是网络请求，有副作用——不能放进 edit 闭包（edit 可能被
    // TaskMutation 重跑一次，重跑网络请求就是把「取一首曲子」算两遍）。
    // 校验、取素材都在这里做完，edit 里只做纯变换。
    List<BgmMaterial>? assignMaterials;
    if (!remove && !(volume != null && materialIds == null)) {
      final ids = <int>[
        for (final p in (materialIds ?? '').split(',')) ?int.tryParse(p.trim()),
      ];
      if (ids.isEmpty) {
        sink.writeln('要说清铺哪几首：--materials 7,8（一段选好几首是互为备选）');
        return exitBadUsage;
      }
      // 取不到就直接失败：铺一段空的进去，导出时那一段会静默没有配乐
      assignMaterials = <BgmMaterial>[];
      for (final id in ids) {
        final m = await fetchMaterial(id);
        if (m == null) {
          sink.writeln('取不到这首曲子：$id。'
              '用 ishkafel script bgm-candidates 重新挑一首');
          return exitFailed;
        }
        assignMaterials.add(m);
      }
    }

    double? setVolume;
    if (!remove && volume != null && materialIds == null) {
      final v = double.tryParse(volume.trim());
      if (v == null || v < 0 || v > 1) {
        sink.writeln('--volume 要 0~1 之间的小数');
        return exitBadUsage;
      }
      setVolume = v;
    }
    final assignVolume =
        double.tryParse((volume ?? '').trim()) ?? BgmSegment.defaultVolume;

    // 配乐是进成片的东西，不是装饰——铺到哪一段要让人看见
    await stage.begin('正在铺配乐', focus: const AgentFocus(module: 'workbench'));
    final updated = await TaskMutation(
      repo: repository,
      dataDir: dataDir,
      by: ActorKind.agent,
      actor: 'Agent',
    ).apply(
      taskId: task.id,
      op: 'bgm.set',
      where: {'fromUnit': from, 'toUnit': to},
      edit: (fresh) {
        final freshUnits = fresh.units ?? const [];
        final beforeSegment =
            fresh.bgm.segments.firstWhereOrNull((s) => s.startUnit == from);
        final BgmPlan next;
        if (remove) {
          next = fresh.bgm.removeSegment(from);
        } else if (setVolume != null) {
          next = fresh.bgm.withVolume(startUnit: from, volume: setVolume);
        } else {
          next = fresh.bgm.assign(
            startUnit: from,
            endUnit: to,
            materials: assignMaterials!,
            rangeMs: unitRangeMs(freshUnits, from: from, to: to),
            volume: assignVolume,
          );
        }
        final afterSegment =
            next.segments.firstWhereOrNull((s) => s.startUnit == from);
        return TaskEdit(
          task: fresh.copyWith(bgm: next),
          before: _bgmSegmentFacts(beforeSegment),
          after: _bgmSegmentFacts(afterSegment),
        );
      },
    );
    if (updated == null) {
      sink.writeln('这条任务在操作过程中被删掉了：${task.id}');
      return exitNotFound;
    }
    emitJson({
      'ok': true,
      'segments': [
        for (final s in updated.bgm.segments)
          {'fromUnit': s.startUnit, 'toUnit': s.endUnit, 'count': s.materials.length},
      ],
    }, out: out);
    return 0;
  } finally {
    stage.end();
    lock.release(who);
  }
}

/// 配乐段落里值得记进日志的事实：铺了哪几首、音量多少——不是「哪个 id」，
/// 是「这一段现在是什么状态」，Agent 才能从改前改后对出人到底动了什么
Map<String, dynamic> _bgmSegmentFacts(BgmSegment? s) => s == null
    ? {'present': false}
    : {
        'present': true,
        'fromUnit': s.startUnit,
        'toUnit': s.endUnit,
        'materials': [for (final m in s.materials) {'id': m.id, 'name': m.name}],
        'volume': s.volume,
      };

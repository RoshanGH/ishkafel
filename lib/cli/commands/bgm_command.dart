import 'dart:io';

import '../../core/audio/bgm_plan.dart';
import '../../core/audio/bgm_range.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_seq.dart';
import '../agent_lock_holder.dart';
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

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  final who = holder ?? agentLockHolder;
  if (!lock.acquire(who)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，先等它');
    return exitLocked;
  }
  try {
    BgmPlan next;
    if (remove) {
      next = task.bgm.removeSegment(from);
    } else if (volume != null && materialIds == null) {
      final v = double.tryParse(volume.trim());
      if (v == null || v < 0 || v > 1) {
        sink.writeln('--volume 要 0~1 之间的小数');
        return exitBadUsage;
      }
      next = task.bgm.withVolume(startUnit: from, volume: v);
    } else {
      final ids = <int>[
        for (final p in (materialIds ?? '').split(',')) ?int.tryParse(p.trim()),
      ];
      if (ids.isEmpty) {
        sink.writeln('要说清铺哪几首：--materials 7,8（一段选好几首是互为备选）');
        return exitBadUsage;
      }
      // 取不到就直接失败：铺一段空的进去，导出时那一段会静默没有配乐
      final materials = <BgmMaterial>[];
      for (final id in ids) {
        final m = await fetchMaterial(id);
        if (m == null) {
          sink.writeln('取不到这首曲子：$id。'
              '用 ishkafel script bgm-candidates 重新挑一首');
          return exitFailed;
        }
        materials.add(m);
      }
      next = task.bgm.assign(
        startUnit: from,
        endUnit: to,
        materials: materials,
        rangeMs: unitRangeMs(units, from: from, to: to),
        volume: double.tryParse((volume ?? '').trim()) ??
            BgmSegment.defaultVolume,
      );
    }
    await repository.save(task.copyWith(bgm: next, updatedAt: DateTime.now()));
    emitJson({
      'ok': true,
      'segments': [
        for (final s in next.segments)
          {'fromUnit': s.startUnit, 'toUnit': s.endUnit, 'count': s.materials.length},
      ],
    }, out: out);
    return 0;
  } finally {
    lock.release(who);
  }
}

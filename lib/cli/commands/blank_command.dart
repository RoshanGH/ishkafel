import 'dart:io';

import '../../core/editing/blank_unit_ops.dart';
import '../../core/editing/blank_unit_removal.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/renew_task.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/models/unit_uid.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_seq.dart';
import '../agent_lock_holder.dart';
import '../cli_output.dart';
import '../task_view.dart';
import 'analyze_command.dart';

/// `ishkafel blank <create|add|remove|tags> …` —— 空白任务（不用原片，从素材拼）。
///
/// 与 GUI 完全同一套规则：分子保底 [blankMinUnits] 个；删分子时替换方案与
/// 配乐区间跟着挪；标签必须逐字命中标签组词表。Agent 走到的每一条约束都和
/// 人在界面上撞到的一样——两边不一致的话，Agent 做出来的任务人一打开就是错的。
Future<int> runBlankCommand({
  required List<String> rest,
  required Directory dataDir,
  String? name,
  String? tagGroups,
  int? unit,
  String? tags,
  String? holder,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel blank create --name <名> --tag-groups <id,id>\n'
        '     ishkafel blank add <任务 id>\n'
        '     ishkafel blank remove <任务 id> --unit <下标>\n'
        '     ishkafel blank tags <任务 id> --unit <下标> --tags <标签,标签>');
    return exitBadUsage;
  }
  final what = rest.first;
  final repository = FileTaskRepository(dataDir);

  if (what == 'create') {
    return _create(repository, sink, out ?? stdout,
        name: name, tagGroups: tagGroups);
  }

  if (rest.length < 2) {
    sink.writeln('少了任务 id。用法：ishkafel blank $what <任务 id> …');
    return exitBadUsage;
  }
  final id = rest[1];
  final task = await resolveTaskRef(repository, id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  if (!task.isBlank) {
    sink.writeln('$id 不是空白任务。add/remove/tags 只对「不用原片，从素材拼」'
        '的任务有意义——有原片的任务，分子是分析切出来的，不能手动增删');
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!lock.acquire(holder ?? agentLockHolder)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，改不了');
    return exitLocked;
  }
  try {
    return switch (what) {
      'add' => await _add(repository, dataDir, task, sink, out ?? stdout),
      'remove' => await _remove(
          repository, dataDir, task, unit, sink, out ?? stdout),
      'tags' => await _tags(
          repository, dataDir, task, unit, tags, sink, out ?? stdout),
      _ => () {
          sink.writeln('认不出「$what」。可用：create / add / remove / tags');
          return exitBadUsage;
        }(),
    };
  } finally {
    lock.release(holder ?? agentLockHolder);
  }
}

Future<int> _create(
  FileTaskRepository repository,
  StringSink sink,
  StringSink out, {
  String? name,
  String? tagGroups,
}) async {
  final ids = [
    for (final piece in (tagGroups ?? '').split(',')) ?int.tryParse(piece.trim()),
  ];
  if (ids.isEmpty) {
    // 标签组是打标的受控词表，也是后面按标签检索素材的检索键。
    // 没有它这条任务什么素材都搜不出来——建出来也是个残废
    sink.writeln('空白任务必须给 --tag-groups（标签是唯一的检索键）。'
        '可用 ishkafel tag-groups 查看可选项');
    return exitBadUsage;
  }
  final all = await MiaoaTagService().listGroups();
  final groups = [
    for (final g in all)
      if (ids.contains(g.id)) TagGroupRef(id: g.id, name: g.name),
  ];
  final missing = ids.where((id) => !groups.any((g) => g.id == id)).toList();
  if (missing.isNotEmpty) {
    sink.writeln('这些标签组在当前企业下找不到：${missing.join('、')}');
    return exitNotFound;
  }

  var laid = BlankUnitOps.append(const []);
  while (laid.length < blankMinUnits) {
    laid = BlankUnitOps.append(laid);
  }

  final now = DateTime.now();
  final task = RenewTask(
    id: now.microsecondsSinceEpoch.toRadixString(36),
    seq: await nextTaskSeq(repository),
    name: (name ?? '').trim().isEmpty ? '拼片任务' : name!.trim(),
    sourcePath: null,
    units: laid,
    status: RenewTaskStatus.ready,
    createdAt: now,
    updatedAt: now,
    unitTagGroups: groups,
  );
  await repository.save(task);
  emitJson(taskToJson(task), out: out);
  return 0;
}

TaskMutation _mutation(FileTaskRepository repository, Directory dataDir) =>
    TaskMutation(
        repo: repository, dataDir: dataDir, by: ActorKind.agent, actor: 'Agent');

int _taskGoneDuring(String taskId, StringSink sink) {
  sink.writeln('这条任务在操作过程中被删掉了：$taskId');
  return exitNotFound;
}

/// 按 uid 在 fresh 里重新定位这个单元；uid 是空串时退回外层算出来的下标。
/// 与 unit_command.dart 的同名函数同一个理由，见那边的文档注释
int _locateUnit(List<SemanticUnit> freshUnits, String uid, int fallbackIndex) {
  if (isUnitUid(uid)) return freshUnits.indexWhere((u) => u.uid == uid);
  return fallbackIndex >= 0 && fallbackIndex < freshUnits.length
      ? fallbackIndex
      : -1;
}

Future<int> _add(FileTaskRepository repository, Directory dataDir,
    RenewTask task, StringSink sink, StringSink out) async {
  final updated = await _mutation(repository, dataDir).apply(
    taskId: task.id,
    op: 'unit.add',
    edit: (fresh) {
      final before = fresh.units ?? const [];
      final after = BlankUnitOps.append(before);
      return TaskEdit(
        task: fresh.copyWith(units: after),
        before: {'unitCount': before.length},
        after: {'unitCount': after.length},
        stampUnits: after.length > before.length ? [after.last.uid] : const [],
      );
    },
  );
  if (updated == null) return _taskGoneDuring(task.id, sink);
  emitJson(taskToJson(updated), out: out);
  return 0;
}

Future<int> _remove(FileTaskRepository repository, Directory dataDir,
    RenewTask task, int? unit, StringSink sink, StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  if (units.length <= blankMinUnits) {
    sink.writeln('至少要留 $blankMinUnits 个分子，删不了');
    return exitBadUsage;
  }
  final removedUid = units[unit].uid;
  final updated = await _mutation(repository, dataDir).apply(
    taskId: task.id,
    op: 'unit.remove',
    where: {'unitUid': removedUid},
    edit: (fresh) {
      final freshUnits = fresh.units ?? const [];
      // unit 是外层那份旧快照的下标，fresh 里单元顺序可能已经变了——
      // 按 uid 重新定位，不能直接拿 unit 当 fresh 的下标用
      final ui = _locateUnit(freshUnits, removedUid, unit);
      if (ui < 0) {
        return TaskEdit(
          task: fresh,
          before: {'present': false},
          after: {'present': false, 'note': '这个单元在窗口内已经被删掉了'},
        );
      }
      // 配乐区间还是按下标记的，必须跟着挪。替换方案按单元的身份记，
      // 只需要把没人认领的那条丢掉
      final left = BlankUnitOps.removeAt(freshUnits, ui);
      final live = {for (final u in left) u.uid};
      return TaskEdit(
        task: fresh.copyWith(
          units: left,
          replacementsByUid: {
            for (final e in fresh.replacementsByUid.entries)
              if (live.contains(e.key)) e.key: e.value,
          },
          bgm: shiftBgmAfterRemoval(fresh.bgm, removed: ui),
        ),
        before: {
          'transcript': freshUnits[ui].transcript,
          'tags': freshUnits[ui].tags,
        },
        after: {'unitCount': left.length},
      );
    },
  );
  if (updated == null) return _taskGoneDuring(task.id, sink);
  emitJson(taskToJson(updated), out: out);
  return 0;
}

Future<int> _tags(FileTaskRepository repository, Directory dataDir,
    RenewTask task, int? unit, String? tags, StringSink sink,
    StringSink out) async {
  final units = task.units ?? const [];
  if (unit == null || unit < 0 || unit >= units.length) {
    sink.writeln('要给 --unit <下标>（0 起，当前 ${units.length} 个）');
    return exitBadUsage;
  }
  final wanted = [
    for (final piece in (tags ?? '').split(','))
      if (piece.trim().isNotEmpty) piece.trim(),
  ];
  // 与 GUI、apply tags 同一条规矩：标签必须逐字命中词表，词表外的一律拒绝。
  // 「厨房场景」和「厨房情景」在检索时是两回事。这一步是网络请求，留在 edit 之外
  final vocabulary = (await vocabularyFor(task.unitTagGroups)).toSet();
  final unknown = wanted.where((t) => !vocabulary.contains(t)).toList();
  if (unknown.isNotEmpty) {
    sink.writeln('这些标签不在受控词表里：${unknown.join('、')}。'
        '词表见 ishkafel task ${task.id} 或 todo 输出');
    return exitBadUsage;
  }

  final targetUid = units[unit].uid;
  final updated = await _mutation(repository, dataDir).apply(
    taskId: task.id,
    op: 'unit.tags',
    where: {'unitUid': targetUid},
    edit: (fresh) {
      final freshUnits = fresh.units ?? const [];
      // unit 是外层那份旧快照的下标——按 uid 重新定位，不能直接拿 unit
      // 当 fresh 的下标用
      final ui = _locateUnit(freshUnits, targetUid, unit);
      if (ui < 0) {
        return TaskEdit(
          task: fresh,
          before: {'present': false},
          after: {'present': false, 'note': '这个单元在窗口内已经被删掉了'},
        );
      }
      final before = freshUnits[ui].tags;
      return TaskEdit(
        task: fresh.copyWith(units: BlankUnitOps.setTags(freshUnits, ui, wanted)),
        before: {'tags': before},
        after: {'tags': wanted},
        stampUnits: [targetUid],
      );
    },
  );
  if (updated == null) return _taskGoneDuring(task.id, sink);
  emitJson(taskToJson(updated), out: out);
  return 0;
}

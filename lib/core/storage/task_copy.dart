/// 复制一条任务。**两条任务之间完全隔离。**
///
/// 用户 2026-09-14 定的：「给一个复制的能力，它可以复制一个一模一样的任务，
/// 但是两个任务要完全隔离……比如我想对第 3 号任务复制，那我就复制出来一个，
/// 它有可能是第 8 或者第 9，无所谓，然后它再进去替换就好了。」
///
/// 「隔离」不是把那份 JSON 抄一遍就完了——任务在磁盘上还带着一堆产物，
/// 而**任务里存着指向它们的绝对路径**。照抄的话，副本的人声轨、配音、封面
/// 全都指着原任务名下的文件：删掉原任务，副本当场瞎掉，而且哪儿都不报错。
///
/// 所以复制干三件事：
///
/// 1. **该带的产物跟着走**（见 [TaskArtifacts.copyOnDuplicateDirNames]）——
///    判据是「丢了副本会瞎，或者重算要花钱」；派生的一律不带，用到自然重建。
/// 2. **任务里存的每一条路径都改写到新任务名下**。做法是把整份 JSON 走一遍，
///    凡是落在数据目录里、且路径上带着老任务 id 的，一律换成新 id——
///    比逐个字段搬更稳：以后新增一种带路径的字段，这里自动就管到了。
///    用户自己的原片路径不在数据目录里，原样不动。
/// 3. **属于「那一次」的东西不抄**：导出历史、AI 用量、首次可用耗时、
///    上次的分析报错。副本没导过片子、没花过钱、也没让人等过。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/renew_task.dart';
import 'task_artifacts.dart';

/// 复制不动的任务：还在分析的不给复制。
///
/// 分析中的任务产物只有一半，抄过去的副本既不能用、又看不出为什么——
/// 与其给一个坏掉的副本，不如说清楚「等它分析完」
String? taskCopyBlockedReason(RenewTask task) =>
    task.status == RenewTaskStatus.analyzing
        ? '这条任务还在分析，等它analyzed完再复制——现在复制出来的副本只有一半产物'
        : null;

/// 副本叫什么。重复复制时继续往后排：「X 的副本」「X 的副本 2」…
String copiedTaskName(String original, Iterable<String> existing) {
  final base = '$original 的副本';
  if (!existing.contains(base)) return base;
  for (var n = 2; n <= 99; n++) {
    if (!existing.contains('$base $n')) return '$base $n';
  }
  return base;
}

class TaskCopier {
  final Directory dataDir;

  /// 拷目录用。注入是为了测试能验「拷了哪些、没拷哪些」而不真的搬文件
  final Future<void> Function(Directory from, Directory to)? copyDir;

  TaskCopier(this.dataDir, {this.copyDir});

  TaskArtifacts get _artifacts => TaskArtifacts(dataDir);

  /// 复制 [src]，返回新任务（**调用方负责落库**）。
  ///
  /// [newId] 新的机器身份，[seq] 新的短编号（人念得出口的那个 #N），
  /// [name] 不给就按 [copiedTaskName] 起。
  Future<RenewTask> duplicate(
    RenewTask src, {
    required String newId,
    required int? seq,
    required DateTime now,
    String? name,
  }) async {
    final blocked = taskCopyBlockedReason(src);
    if (blocked != null) throw StateError(blocked);

    await _copyArtifacts(src.id, newId);

    // 整份 JSON 走一遍改路径：逐个字段搬的话，以后新增一种带路径的字段
    // 就会被漏掉，而漏掉的表现是「删了原任务，副本悄悄坏一半」
    final json = _rewritePaths(src.toJson(), src.id, newId)
        as Map<String, dynamic>;

    // **在 JSON 这一层改身份**，不走 copyWith：`??` 语义清不掉可空字段
    // （firstReadyMs / analysisError 要的正是「清成 null」），而逐个字段
    // 重建一个 RenewTask 又会漏掉以后新增的字段——这份 JSON 是全的
    json['id'] = newId;
    json['name'] = name ?? '${src.name} 的副本';
    json['createdAt'] = now.toIso8601String();
    json['updatedAt'] = now.toIso8601String();
    if (seq == null) {
      json.remove('seq');
    } else {
      json['seq'] = seq;
    }
    // 属于「那一次」的东西不抄：副本没导过片子、没花过钱、没让人等过，
    // 上次那个分析错误也不是它的
    json['exports'] = const [];
    json.remove('aiUsage');
    json.remove('firstReadyMs');
    json.remove('analysisError');

    return RenewTask.fromJson(json);
  }

  /// 把该带走的产物拷到新任务名下
  Future<void> _copyArtifacts(String oldId, String newId) async {
    for (final name in TaskArtifacts.copyOnDuplicateDirNames) {
      await _copy(
        Directory(p.join(dataDir.path, name, oldId)),
        Directory(p.join(dataDir.path, name, newId)),
      );
    }
    // 人声/背景轨与封面不在「一个任务一个子目录」那一套里，单独搬
    await _copy(
      Directory(p.join(_artifacts.stemsDir.path, oldId)),
      Directory(p.join(_artifacts.stemsDir.path, newId)),
    );
    final cover = File(p.join(_artifacts.coversDir.path, '$oldId.jpg'));
    if (cover.existsSync()) {
      final dest = File(p.join(_artifacts.coversDir.path, '$newId.jpg'));
      dest.parent.createSync(recursive: true);
      await cover.copy(dest.path);
    }
  }

  Future<void> _copy(Directory from, Directory to) async {
    if (!from.existsSync()) return;
    if (copyDir != null) return copyDir!(from, to);
    to.createSync(recursive: true);
    for (final entity in from.listSync(recursive: true, followLinks: false)) {
      final rel = p.relative(entity.path, from: from.path);
      final target = p.join(to.path, rel);
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        await entity.copy(target);
      }
    }
  }

  /// 把 JSON 里所有指向老任务产物的路径改写到新任务名下。
  ///
  /// 只动**数据目录里**的路径：用户自己的原片放在别处，那是他的文件，
  /// 一个字节都不该碰
  Object? _rewritePaths(Object? node, String oldId, String newId) {
    if (node is Map) {
      return <String, dynamic>{
        for (final e in node.entries)
          '${e.key}': _rewritePaths(e.value, oldId, newId),
      };
    }
    if (node is List) {
      return [for (final v in node) _rewritePaths(v, oldId, newId)];
    }
    if (node is String) return _rewriteOne(node, oldId, newId);
    return node;
  }

  String _rewriteOne(String value, String oldId, String newId) {
    if (!value.contains(oldId)) return value;
    if (!p.isWithin(dataDir.path, value)) return value;
    final segments = p.split(value);
    return p.joinAll([
      for (final s in segments)
        if (s == oldId)
          newId
        else if (s.startsWith('$oldId.'))
          '$newId${s.substring(oldId.length)}'
        else
          s,
    ]);
  }

  /// 这一次复制会带走多少字节（界面上先说清楚要占多大）
  int estimatedBytes(String taskId) {
    var total = 0;
    for (final name in TaskArtifacts.copyOnDuplicateDirNames) {
      final dir = Directory(p.join(dataDir.path, name, taskId));
      if (dir.existsSync()) total += TaskArtifacts.sizeOf(dir);
    }
    final stems = Directory(p.join(_artifacts.stemsDir.path, taskId));
    if (stems.existsSync()) total += TaskArtifacts.sizeOf(stems);
    final cover = File(p.join(_artifacts.coversDir.path, '$taskId.jpg'));
    if (cover.existsSync()) total += TaskArtifacts.sizeOf(cover);
    return total;
  }
}


import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// **界面现在停在哪一页。**
///
/// 可视模式成立的前提是「人看得见」。而在场状态（[AgentPresence]）只回答
/// 「Agent 在干什么」，回答不了「人此刻看得见吗」——两者差着一整个界面。
///
/// 真机上就栽在这个差上：脚本成片的配音在横幅上一句句念「正在给第 10 句
/// 配音（10/20）」，而界面停在任务列表，二十句从头到尾没有任何一格出现在
/// 屏幕上。播报没说谎，可视化却根本没发生——**它成了换了个地方显示的日志**。
///
/// 所以 Agent 每走一步都要先问一句「界面在哪、我要它去哪」（见
/// [AgentStage]）。这份文件就是那一问的答案：界面自己写，CLI 读。
///
/// 为什么由界面写而不是 CLI 猜：只有界面知道人刚才有没有自己退出去。
/// CLI 无脑每步都发唤醒的话，人想退出去看看别的都退不掉——刚点返回就
/// 被拽回来。
class UiWhere {
  /// 停在哪个模块：`tasks` / `director` / `workbench` / `review`
  final String module;

  /// 停在哪条任务上；`tasks`（任务列表）没有任务，是 null
  final String? taskId;

  /// 心跳时刻。超过 [staleAfter] 没更新就当界面已经不在了（关掉了、崩了）
  final DateTime at;

  const UiWhere({required this.module, required this.taskId, required this.at});

  /// 界面每 [beatEvery] 写一次，容三次没写上（卡顿、正在跳转）再判定不在
  static const Duration beatEvery = Duration(seconds: 2);
  static const Duration staleAfter = Duration(seconds: 7);

  bool get isStale => DateTime.now().difference(at) > staleAfter;

  /// 人此刻正看着这个任务的这个模块吗
  bool isOn({required String module, required String taskId}) =>
      !isStale && this.module == module && this.taskId == taskId;

  /// 人此刻正看着这条任务吗（不挑模块）。
  /// 有些步骤不指定去哪个模块，由界面按任务类型自己选——那时只问到这一层
  bool isOnTask(String taskId) => !isStale && this.taskId == taskId;
}

File _whereFile(Directory dataDir) => File(p.join(dataDir.path, 'ui_where.json'));

/// 界面报个到：我在这一页。**只有栈顶那一页该写**——被盖住的页面人看不见，
/// 它要是也写就会把真相盖掉
void writeUiWhere(Directory dataDir, {required String module, String? taskId}) {
  try {
    _whereFile(dataDir)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({
        'module': module,
        'task': ?taskId,
        'at': DateTime.now().toIso8601String(),
      }));
  } catch (_) {
    // 报到失败不该拖累界面：最坏的结果是 Agent 多发一次唤醒，
    // 而界面本来就会对「已经在这一页」的唤醒视而不见
  }
}

/// 界面在哪？读不到（没开、刚崩、还没写第一次）返回 null
UiWhere? readUiWhere(Directory dataDir) {
  final file = _whereFile(dataDir);
  if (!file.existsSync()) return null;
  try {
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map) return null;
    final module = raw['module'];
    final at = DateTime.tryParse('${raw['at']}');
    if (module is! String || module.isEmpty || at == null) return null;
    return UiWhere(
      module: module,
      taskId: raw['task'] is String ? raw['task'] as String : null,
      at: at,
    );
  } catch (_) {
    return null;
  }
}

/// 界面退场（关窗、退到后台）时清掉，别让 CLI 以为人还在看
void clearUiWhere(Directory dataDir) {
  try {
    final f = _whereFile(dataDir);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

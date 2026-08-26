import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/app_log.dart';
import 'task_lock.dart';

/// Agent 此刻在这个任务上**干什么、看哪儿**。
///
/// 任务锁只回答「谁占着」，不够——用户要的是看得懂它在动什么：
///
/// > 它选中第 10 行，那就跟人一样把第 10 行放到界面中间；它去调某一镜的
/// > 时长或变速，那个面板就打开，跟人自己点开去调的时候是一样的。
///
/// **焦点必须由 Agent 主动上报**，不能靠界面从数据变化里猜：它可能读了半天
/// 才动手，也可能一次改好几行——人在旁边看的是**过程**，不是结果差异。
///
/// 与任务锁同一条自愈规矩：心跳停了就当它不在（见 [defaultStaleAfter]），
/// 否则 Agent 一崩，界面会一直以为有人占着。
class AgentPresence {
  /// 谁在（`Agent` / `人（编导台）`）——横幅上要说得出名字
  final String holder;

  /// 心跳时刻。超过 [defaultStaleAfter] 没更新就视为不在场
  final DateTime at;

  /// 正在做什么，**人话**：「正在给第 10 句挑镜头」。直接显示在横幅上
  final String action;

  /// 界面该把哪儿摆到眼前；null = 它还没动到具体某一行（在读、在想）
  final AgentFocus? focus;

  const AgentPresence({
    required this.holder,
    required this.at,
    required this.action,
    this.focus,
  });

  bool isStale(DateTime now, {Duration staleAfter = defaultStaleAfter}) =>
      now.difference(at) > staleAfter;

  Map<String, dynamic> toJson() => {
        'holder': holder,
        'at': at.toIso8601String(),
        'action': action,
        if (focus != null) 'focus': focus!.toJson(),
      };

  /// 宽松解析：**任何一处不对就返回 null**，由调用方当作「没人在」。
  /// 一个读不懂的状态文件不该把界面卡在只读上
  static AgentPresence? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final holder = raw['holder'];
    final at = DateTime.tryParse('${raw['at']}');
    if (holder is! String || holder.isEmpty || at == null) return null;
    return AgentPresence(
      holder: holder,
      at: at,
      action: raw['action'] is String ? raw['action'] as String : '',
      focus: AgentFocus.tryFromJson(raw['focus']),
    );
  }
}

/// 界面该把哪儿摆到眼前
class AgentFocus {
  /// 哪一行（0 起）
  final int lineIndex;

  /// 哪一镜（0 起）；null = 整行，不针对某一镜
  final int? shotIndex;

  /// 该展开哪个面板——**跟人自己点开时是同一个面板**，不另造只读展示
  final AgentPanel panel;

  const AgentFocus({
    required this.lineIndex,
    this.shotIndex,
    this.panel = AgentPanel.none,
  });

  Map<String, dynamic> toJson() => {
        'lineIndex': lineIndex,
        if (shotIndex != null) 'shotIndex': shotIndex,
        'panel': panel.name,
      };

  static AgentFocus? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final line = raw['lineIndex'];
    if (line is! int || line < 0) return null;
    return AgentFocus(
      lineIndex: line,
      shotIndex: raw['shotIndex'] is int ? raw['shotIndex'] as int : null,
      panel: AgentPanel.values.firstWhere(
        (p) => p.name == raw['panel'],
        orElse: () => AgentPanel.none,
      ),
    );
  }
}

/// 焦点落在哪个面板上。取值与界面上人能点开的面板一一对应
enum AgentPanel {
  /// 只是选中这一行，不展开任何面板
  none,

  /// 镜头详情（取段、速度、原声、时长）
  shot,

  /// 字幕屏列表
  subtitle,

  /// 配音（音色、语速、生成）
  voice,

  /// 配乐段
  bgm,
}

File _presenceFile(Directory dataDir, String taskId) =>
    File(p.join(dataDir.path, 'presence', '$taskId.json'));

/// 上报：Agent 每做一步就更新一次（心跳也靠它）
void writeAgentPresence({
  required Directory dataDir,
  required String taskId,
  required AgentPresence presence,
}) {
  try {
    final f = _presenceFile(dataDir, taskId);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode(presence.toJson()));
  } catch (e) {
    // 上报失败只影响「看得见」，不该让 Agent 的正事失败
    AppLog.warn('Agent 在场状态写入失败（$taskId）：$e');
  }
}

/// 读：心跳停了、文件坏了、根本没有，一律当作「没人在」
AgentPresence? readAgentPresence({
  required Directory dataDir,
  required String taskId,
  DateTime? now,
  Duration staleAfter = defaultStaleAfter,
}) {
  try {
    final f = _presenceFile(dataDir, taskId);
    if (!f.existsSync()) return null;
    final presence = AgentPresence.tryFromJson(jsonDecode(f.readAsStringSync()));
    if (presence == null) return null;
    return presence.isStale(now ?? DateTime.now(), staleAfter: staleAfter)
        ? null
        : presence;
  } catch (e) {
    AppLog.warn('Agent 在场状态读取失败（$taskId）：$e');
    return null;
  }
}

/// 干完活撤掉——别让界面以为它还在
void clearAgentPresence({
  required Directory dataDir,
  required String taskId,
}) {
  try {
    final f = _presenceFile(dataDir, taskId);
    if (f.existsSync()) f.deleteSync();
  } catch (e) {
    AppLog.warn('Agent 在场状态清除失败（$taskId）：$e');
  }
}

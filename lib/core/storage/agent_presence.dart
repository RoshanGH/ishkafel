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

  /// 第几步（每上报一次递增）。
  ///
  /// **可视模式的节奏靠它握手，不靠猜时间**：Agent 发出第 N 步，界面真的
  /// 展示完（滚动停下、面板展开）才回执第 N 步，Agent 收到才走下一步。
  /// 固定等几百毫秒是拍脑袋——机器快的时候白等，慢的时候还是没看清
  final int step;

  const AgentPresence({
    required this.holder,
    required this.at,
    required this.action,
    this.focus,
    this.step = 0,
  });

  bool isStale(DateTime now, {Duration staleAfter = defaultStaleAfter}) =>
      now.difference(at) > staleAfter;

  Map<String, dynamic> toJson() => {
        'holder': holder,
        'at': at.toIso8601String(),
        'action': action,
        'step': step,
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
      step: raw['step'] is int ? raw['step'] as int : 0,
      focus: AgentFocus.tryFromJson(raw['focus']),
    );
  }
}

/// 界面该把哪儿摆到眼前
class AgentFocus {
  /// 去哪个模块：`director`（编导台）/ `workbench`（工作台）/
  /// `review`（审片台）/ `tasks`（任务列表）。
  ///
  /// **这一层是全软件的**：界面有一个统一的导航器负责「没开就拉起来、
  /// 切到那个模块、打开那个任务、滚到位置、弹出那个面板」，各模块只声明
  /// 自己能被导航到哪些位置——不给每个模块各写一套跟随
  final String module;

  /// 哪一行（0 起）。编导台用
  final int lineIndex;

  /// 哪一镜（0 起）；null = 整行，不针对某一镜
  final int? shotIndex;

  /// 哪个语义单元（0 起）。工作台用
  final int? unitIndex;

  /// 该展开哪个面板——**跟人自己点开时是同一个面板**，不另造只读展示
  final AgentPanel panel;

  const AgentFocus({
    this.module = 'director',
    this.lineIndex = 0,
    this.shotIndex,
    this.unitIndex,
    this.panel = AgentPanel.none,
  });

  Map<String, dynamic> toJson() => {
        'module': module,
        'lineIndex': lineIndex,
        if (shotIndex != null) 'shotIndex': shotIndex,
        if (unitIndex != null) 'unitIndex': unitIndex,
        'panel': panel.name,
      };

  static AgentFocus? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final line = raw['lineIndex'];
    if (line is! int || line < 0) return null;
    return AgentFocus(
      module: raw['module'] is String ? raw['module'] as String : 'director',
      lineIndex: line,
      shotIndex: raw['shotIndex'] is int ? raw['shotIndex'] as int : null,
      unitIndex: raw['unitIndex'] is int ? raw['unitIndex'] as int : null,
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

  /// 找镜头面板（人点「添加分镜」弹出来的那个）
  findShots,
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

File _ackFile(Directory dataDir, String taskId) =>
    File(p.join(dataDir.path, 'presence', '$taskId.ack.json'));

/// 界面展示完第 [step] 步了。**这是可视模式的节拍器**——Agent 等到它才走
/// 下一步，所以要在**真的展示完之后**再写（滚动停下、面板展开），
/// 不是收到就写
void writeAgentAck({
  required Directory dataDir,
  required String taskId,
  required int step,
}) {
  try {
    final f = _ackFile(dataDir, taskId);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(
        jsonEncode({'step': step, 'at': DateTime.now().toIso8601String()}));
  } catch (e) {
    AppLog.warn('展示回执写入失败（$taskId）：$e');
  }
}

/// 界面展示到第几步了；读不到就是 -1（还没回过任何一步）
int readAgentAck({required Directory dataDir, required String taskId}) {
  try {
    final f = _ackFile(dataDir, taskId);
    if (!f.existsSync()) return -1;
    final raw = jsonDecode(f.readAsStringSync());
    return raw is Map && raw['step'] is int ? raw['step'] as int : -1;
  } catch (_) {
    return -1;
  }
}

/// 等界面把第 [step] 步展示完。
///
/// 返回 true = 界面确实展示完了；false = 等到超时（**界面没开、崩了、
/// 被关了都算**）。超时**不是错误**：可视只是给人看的，看不成也不该把
/// Agent 的正事卡死——照常往下跑就是了
Future<bool> waitForAck({
  required Directory dataDir,
  required String taskId,
  required int step,
  Duration timeout = const Duration(seconds: 5),
  Duration poll = const Duration(milliseconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (readAgentAck(dataDir: dataDir, taskId: taskId) >= step) return true;
    await Future<void>.delayed(poll);
  }
  return false;
}

/// 干完活把回执也撤掉，免得下一轮把上一轮的回执当成新的
void clearAgentAck({required Directory dataDir, required String taskId}) {
  try {
    final f = _ackFile(dataDir, taskId);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}

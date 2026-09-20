import 'dart:io';

import '../../core/storage/agent_broadcast.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_seq.dart';
import '../agent_stage.dart';
import '../cli_output.dart';

/// `ishkafel say` —— **把话筒交给 Agent**。
///
/// 播报条上分三类（见 [BroadcastKind]），原先三类都只能由命令自己发：
/// 命令做到哪一步就报哪一步。可**判断**这一类根本不属于命令——
/// 「为什么改主意」是 Agent 的事，软件替它说就是替它判断。
///
/// 2026-09-20 真机测出来的洞：判断类播报那天起**一个产生者都没有**。
/// 它原先仅有的两处（标签收窄、结果太宽自动改走语义搜）是软件在替人判断，
/// 当天被整体拆掉了——拆得对，但拆完这一类就空了。而验收标准里写着：
///
/// > **判断类最值钱**。「标签命中 5318 条太宽，改用画面描述再搜一轮」
/// > 这种话，是人肯把花钱的活交给静默模式的唯一理由。
///
/// 正解不是把那句假判断放回去，是把话筒给真正在判断的那个。这条命令因此
/// 也是「人在界面上能拧的每个旋钮，Agent 都要能拧」补上的一个——
/// 而且补在最值钱的那一类上。
///
/// **不改任何数据**，所以不进改动日志（那条日志只记写操作）。
Future<int> runSayCommand({
  required List<String> rest,
  required Directory dataDir,

  /// 「我为什么改主意了」。三个里**只能给一个**
  String? judgement,

  /// 「我发现了一个可能要喊停的问题」
  String? warning,

  /// 「我正在干的这件事没有命令对应」（两条命令之间它自己在看图的那段）
  String? step,

  /// 界面该看哪儿。给了单元/镜头就是工作台，给了行就是编导台；
  /// 都不给就只说话，不把界面拽走
  int? unitIndex,
  int? shotIndex,
  int? lineIndex,
  bool visual = false,
  StringSink? err,

  /// 测试注入：等界面回执的超时。真机走 [AgentStage] 的默认值
  Duration? stepTimeout,
}) async {
  final sink = err ?? stderr;

  final said = <String, String?>{
    '--judgement': judgement,
    '--warning': warning,
    '--step': step,
  }..removeWhere((_, v) => v == null);

  if (said.isEmpty) {
    sink.writeln('这条命令是让你自己说一句话，三选一：\n'
        '  --judgement "标签命中 518 条太宽，我改用画面描述再搜一轮"'
        '   ← 你为什么改主意（最值钱的一类）\n'
        '  --warning   "U2S1 这条素材烧着别家的字，我换掉了"'
        '   ← 人可能要当场喊停\n'
        '  --step      "正在逐条看这 50 个候选的画面"'
        '   ← 你在干的活儿没有命令对应');
    return exitBadUsage;
  }
  if (said.length > 1) {
    sink.writeln('一次只说一句：${said.keys.join('、')} 同时给了，'
        '播报条分不清这是哪一类。分两条命令说');
    return exitBadUsage;
  }

  final kind = switch (said.keys.single) {
    '--judgement' => BroadcastKind.judgement,
    '--warning' => BroadcastKind.warning,
    _ => BroadcastKind.step,
  };
  final text = said.values.single!.trim();
  if (text.isEmpty) {
    sink.writeln('${said.keys.single} 给的是一句空话。'
        '宁可不说，也不占着播报条说废话');
    return exitBadUsage;
  }

  // 不给任务就挂在全局槽上：它在**整个软件**上干活，不是在某一页。
  // 播报条盯着全局槽 + 所有任务槽，两边都看得见
  var slot = globalPresenceSlot;
  if (rest.isNotEmpty) {
    final task = await resolveTaskRef(FileTaskRepository(dataDir), rest.first);
    if (task == null) {
      sink.writeln('没有这个任务：${rest.first}');
      return exitNotFound;
    }
    slot = task.id;
  }

  final mode = AgentStageMode.from(visual: visual);
  if (mode != AgentStageMode.visual) {
    // **不能静静地吞掉**：它以为播出去了，而人那头什么都没看见。
    // 这不是它做错了什么，所以不给失败——但得让它知道这句话没人听见
    sink.writeln('静默模式下没人在看着屏幕，这句话没有播出去。'
        '要它出现在播报条上，加 --visual（或 ISHKAFEL_VISUAL=1）');
    return 0;
  }

  final stage = AgentStage(
    mode: mode,
    dataDir: dataDir,
    taskId: slot,
    stepTimeout: stepTimeout ?? const Duration(seconds: 5),
  );
  await stage.show(text,
      kind: kind, focus: _focusFrom(unitIndex, shotIndex, lineIndex));
  // **不收工**：`end()` 会清掉在场状态，播报条跟着立刻消失——
  // 话刚说完就没了等于没说。留着让它自然过期（或被下一条命令接上），
  // 发现问题那一类尤其要留：人走开一会儿回来，最该看见的就是它
  return 0;
}

/// 说这句话时界面该看哪儿。**都不给就返回 null**——没话要指的时候
/// 硬指一个位置，界面会平白跳一下，而那正是挨过骂的「画面弹回第一行」
AgentFocus? _focusFrom(int? unitIndex, int? shotIndex, int? lineIndex) {
  if (lineIndex != null) {
    return AgentFocus(
      module: 'director',
      lineIndex: lineIndex,
      shotIndex: shotIndex,
      panel: AgentPanel.none,
    );
  }
  if (unitIndex == null) return null;
  return AgentFocus(
    module: 'workbench',
    unitIndex: unitIndex,
    shotIndex: shotIndex,
    panel: AgentPanel.none,
  );
}

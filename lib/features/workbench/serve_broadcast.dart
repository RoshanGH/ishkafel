import 'dart:io';

import '../../core/storage/agent_broadcast.dart';
import '../../core/storage/agent_presence.dart';
import '../agent/visual_pace.dart';

/// 界面**代 Agent 干活时**自己报进度。
///
/// 委派提交方案那条路上，活儿是界面干的、CLI 在那头等着——于是没人写在场
/// 状态，播报条就一片空白。验收 Agent 用 0.3 秒密拍 40 帧确认过：
/// 一帧都没出现过播报。而 CLI 打印的是「人能看着方案落进去」，
/// 那是一句没兑现的话。
///
/// 署名仍然是 `Agent`：活儿是它请托的。写成「界面」的话，
/// 人会以为是自己点的。
class ServeBroadcast {
  final Directory dataDir;
  final String taskId;
  int _step = 0;

  ServeBroadcast({required this.dataDir, required this.taskId});

  /// 说一句，**并停够人眼跟得上的时间**。
  ///
  /// 校验和投影本身是瞬间的，不停的话三句话一闪而过等于没说。
  /// 停多久用全软件同一份节奏（见 [visualStepDwell]）。
  Future<void> sayAndHold(String action,
      {AgentFocus? focus, BroadcastKind kind = BroadcastKind.step}) async {
    say(action, focus: focus, kind: kind);
    await Future<void>.delayed(visualStepDwell);
  }

  /// 发现了会毁掉整片的问题——人可能要当场喊停。
  /// 停得比普通一步久：这一条值得人多看两眼
  Future<void> warnAndHold(String action, {AgentFocus? focus}) async {
    say(action, focus: focus, kind: BroadcastKind.warning);
    await Future<void>.delayed(visualStepDwell * 2);
  }

  /// 说一句。步号递增——播报条据此判断是不是新一步
  void say(String action,
      {AgentFocus? focus, BroadcastKind kind = BroadcastKind.step}) {
    _step++;
    writeAgentPresence(
      dataDir: dataDir,
      taskId: taskId,
      presence: AgentPresence(
        holder: 'Agent',
        at: DateTime.now(),
        action: action,
        step: _step,
        kind: kind,
        focus: focus,
      ),
    );
  }

  /// 干完撤场。不撤的话界面永远停在「Agent 正在操作」的只读态上
  void done() => clearAgentPresence(dataDir: dataDir, taskId: taskId);
}

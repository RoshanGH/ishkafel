import 'dart:io';

import '../core/log/app_log.dart';
import '../core/storage/agent_presence.dart';
import '../core/storage/ui_wake.dart';
import 'commands/open_command.dart' show defaultAppPath;

/// Agent 干活的两种模式。
///
/// 这不是一个技术开关，是两种完全不同的使用场景：
///
/// - **静默**（默认）：人不在场。软件被调起来干活，人回头看结果或直接看成片。
///   不弹窗、不导航、不等回执——快就是好
/// - **可视**：人在场，而且他要**看着**。就像站在实习生旁边：软件自己弹出来，
///   它开哪个模块界面就切到哪个模块，它动哪一行界面就滚到哪一行；人随时能
///   在 Agent 那头喊停、自己上手改、再让它接着看
///
/// 模式由调用方（人对 Agent 说话时）决定，Agent 把它贯穿整个会话——
/// 所以是一个显式的开关，不是软件替它猜。
enum AgentStageMode {
  silent,
  visual;

  static AgentStageMode from({bool? visual, Map<String, String>? env}) {
    if (visual == true) return AgentStageMode.visual;
    final e = env ?? Platform.environment;
    final flag = (e['ISHKAFEL_VISUAL'] ?? '').trim().toLowerCase();
    return const ['1', 'true', 'yes', 'on'].contains(flag)
        ? AgentStageMode.visual
        : AgentStageMode.silent;
  }
}

/// 「舞台」：可视模式下，Agent 每做一步都在这里说一声，界面跟着走。
///
/// 静默模式下它什么都不做（连文件都不写）——那条路径要保持原来的速度。
class AgentStage {
  final AgentStageMode mode;
  final Directory dataDir;
  final String taskId;
  final String holder;

  /// 等界面展示完一步最多等多久。超时不算错——界面没开也不该把正事卡死
  final Duration stepTimeout;

  final Future<ProcessResult> Function(String, List<String>) _run;

  int _step = 0;
  bool _appLaunched = false;

  AgentStage({
    required this.mode,
    required this.dataDir,
    required this.taskId,
    this.holder = 'Agent',
    this.stepTimeout = const Duration(seconds: 5),
    Future<ProcessResult> Function(String, List<String>)? run,
  }) : _run = run ?? Process.run;

  bool get visual => mode == AgentStageMode.visual;

  /// 开工：可视模式下把软件拉起来并落到这个任务上。
  /// 已经开着就不会重复弹（`open -a` 只是把它带到前台）
  Future<void> begin(String action, {AgentFocus? focus}) async {
    if (!visual) return;
    clearAgentAck(dataDir: dataDir, taskId: taskId);
    await _launchApp();
    await show(action, focus: focus);
  }

  /// 走一步：说清在做什么、界面该看哪儿，然后**等它真的展示完**。
  ///
  /// 节奏由界面决定而不是猜时间——界面滚动完、面板展开完才回执。
  /// 机器快的时候不白等，慢的时候也不会一闪而过没看清
  Future<void> show(String action, {AgentFocus? focus}) async {
    if (!visual) return;
    _step++;
    writeAgentPresence(
      dataDir: dataDir,
      taskId: taskId,
      presence: AgentPresence(
        holder: holder,
        at: DateTime.now(),
        action: action,
        step: _step,
        focus: focus,
      ),
    );
    final shown = await waitForAck(
      dataDir: dataDir,
      taskId: taskId,
      step: _step,
      timeout: stepTimeout,
    );
    if (!shown) {
      AppLog.info('界面没跟上第 $_step 步（可能没开着），照常往下跑');
    }
  }

  /// 心跳：长活儿（配音、导出）每隔一会儿报一次，让界面知道它还在
  void heartbeat(String action, {AgentFocus? focus}) {
    if (!visual) return;
    writeAgentPresence(
      dataDir: dataDir,
      taskId: taskId,
      presence: AgentPresence(
        holder: holder,
        at: DateTime.now(),
        action: action,
        step: _step,
        focus: focus,
      ),
    );
  }

  /// 收工：把在场状态撤掉，界面立刻恢复可操作。
  /// **被打断时也要走这里**——不然人要等一分钟心跳超时才能动手
  void end() {
    clearAgentPresence(dataDir: dataDir, taskId: taskId);
    clearAgentAck(dataDir: dataDir, taskId: taskId);
  }

  Future<void> _launchApp() async {
    if (_appLaunched) return;
    _appLaunched = true;
    final path = Platform.environment['ISHKAFEL_APP'] ?? defaultAppPath;
    try {
      // 「去哪个任务」走唤醒文件而不是 --args：启动参数只在冷启动时生效，
      // app 已经在跑时会被静默丢弃（`open` 命令那边真机撞到过——再点一次
      // 只是把窗口调到前台，什么都不发生）。文件冷热启动一条路
      writeUiWake(dataDir, taskId, review: false);
      await _run('open', ['-a', path]);
    } catch (e) {
      AppLog.warn('拉起 app 失败（可视模式退化成静默）：$e');
    }
  }
}

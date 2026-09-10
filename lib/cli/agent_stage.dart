import 'dart:io';

import 'package:meta/meta.dart';

import '../core/log/app_log.dart';
import '../core/storage/agent_broadcast.dart';
import '../core/storage/agent_presence.dart';
import '../core/storage/ui_wake.dart';
import '../core/storage/ui_where.dart';
import 'app_locator.dart';

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

  /// 连着这么多步没回执就不再等。**状态照写**（界面随时可能开起来接上），
  /// 只是不再为它停下来
  static const int _giveUpAfter = 2;

  /// 连着几步没人回执了
  int _unanswered = 0;

  /// **为了它等过几次超时**。放弃等待这条规则的效果只能靠「等了几次」来验，
  /// 拿墙钟量会在机器忙的时候假红（真机全量跑撞到过三次）
  @visibleForTesting
  int waitedCount = 0;

  final Future<ProcessResult> Function(String, List<String>) _run;

  /// 测试注入：app 在不在。真机走默认（看目录存不存在）
  final bool Function(String path)? appExists;

  int _step = 0;
  bool _appLaunched = false;

  /// 上一次问「界面在哪」是什么时候（见 [_ensureOnStage] 的节流）
  DateTime _lastCheckedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一次叫界面过来是什么时候。叫完给它 [_settleTime] 落位，
  /// 这期间不再叫——正在跳转的页面经不起第二次唤醒
  DateTime _lastWakeAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastWakeModule;
  static const Duration _settleTime = Duration(seconds: 3);

  AgentStage({
    required this.mode,
    required this.dataDir,
    required this.taskId,
    this.holder = 'Agent',
    this.stepTimeout = const Duration(seconds: 5),
    Future<ProcessResult> Function(String, List<String>)? run,
    this.appExists,
  }) : _run = run ?? Process.run;

  bool get visual => mode == AgentStageMode.visual;

  /// 开工：可视模式下把软件拉起来并落到这个任务上。
  /// 已经开着就不会重复弹（`open -a` 只是把它带到前台）
  Future<void> begin(String action, {AgentFocus? focus}) async {
    if (!visual) return;
    clearAgentAck(dataDir: dataDir, taskId: taskId);
    await _launchApp(module: focus?.module);
    await show(action, focus: focus);
  }

  /// 走一步：说清在做什么、界面该看哪儿，然后**等它真的展示完**。
  ///
  /// 节奏由界面决定而不是猜时间——界面滚动完、面板展开完才回执。
  /// 机器快的时候不白等，慢的时候也不会一闪而过没看清
  /// 说一句「它为什么改主意了」。
  ///
  /// 和进度分开报是有讲究的：进度是流水账（「正在给 U2S4 挑素材」），
  /// 判断才是人真正想看的（「标签命中 5318 条太宽，改用画面描述再搜一轮」）。
  /// **人肯把花钱的活交给静默模式，靠的正是看懂过它是怎么想的。**
  Future<void> think(String action, {AgentFocus? focus}) =>
      show(action, focus: focus, kind: BroadcastKind.judgement);

  /// 说一句「发现问题了」——人可能要当场喊停。
  ///
  /// 只用在**会毁掉整片**的发现上（素材烧着别家的字、画面里露的是竞品），
  /// 不用在能自己接着走的小磕碰上。喊多了狼来了，真出事那次就没人看了。
  Future<void> warn(String action, {AgentFocus? focus}) =>
      show(action, focus: focus, kind: BroadcastKind.warning);

  /// **开工前先确认现场**：界面此刻在哪一页、这一步该在哪一页看。
  ///
  /// 不在就把它带过去；已经在就什么都不做。
  ///
  /// 这一问必须**每一步都问**，不能只在开头问一次。真机上栽过：脚本成片
  /// 的配音全程在横幅上念「正在给第 10 句配音（10/20）」，界面却停在任务
  /// 列表，二十句没有一格出现在屏幕上——播报没说谎，可视化却没发生。
  /// 产品负责人的话：「它并不判断当前是否是它执行的那个页面，这样的话
  /// 可视化的意义就没有了。」被打断之后接着干的那一次尤其要问，因为人在
  /// 打断的间隙多半已经把界面切走了。
  ///
  /// 为什么要先读一眼界面在哪、而不是无脑每步都发唤醒：唤醒会把目标页面
  /// 关掉重开（滚动位置、展开的镜头全丢）。已经在现场还发，人看到的是
  /// 画面不停地弹回第一行——那个毛病挨过骂，不能再犯。
  /// [throttle] 给心跳用：导出的进度回调一镜一跳（几百毫秒一次），
  /// 没必要每跳都去读盘。**步骤（[show]）一律不节流**——一步就是一个
  /// 交代，每一步都得当场确认人看得见。
  void _ensureOnStage(String? module, {bool throttle = false}) {
    if (!visual) return;
    // 全局槽上的活儿（导入）还没有任务可跳，状态显示在任务列表页上
    if (taskId == globalPresenceSlot) return;
    if (throttle) {
      final now = DateTime.now();
      if (now.difference(_lastCheckedAt) < const Duration(seconds: 1)) return;
      _lastCheckedAt = now;
    }
    // 没指定模块的步骤（导出、剪映草稿这类整片的活儿）只问到「在这条任务上」
    // 就够——去编导台还是工作台由界面按任务类型自己选
    final where = readUiWhere(dataDir);
    final onScene = module == null
        ? where?.isOnTask(taskId) == true
        : where?.isOn(module: module, taskId: taskId) == true;
    if (onScene) return;
    // 已经叫过、它还没取走：**它在路上，不是不肯来**。重复写只是把同一条
    // 覆盖一遍；界面没开时更是每一步都白写一次
    if (hasPendingUiWake(dataDir)) return;
    // 取走了但还没报到：多半正在跳转（关掉旧页、开新页要几百毫秒）。
    // 这几百毫秒里再叫一次，界面就会把刚开到一半的页面再销毁重建一次——
    // 人看到的正是那个挨过骂的「画面弹回第一行」
    // 只对**同一个去处**留宽限：换模块是新的目的地，要立刻带过去
    if (module == _lastWakeModule &&
        DateTime.now().difference(_lastWakeAt) < _settleTime) {
      return;
    }
    _lastWakeModule = module;
    _lastWakeAt = DateTime.now();
    writeUiWake(dataDir, taskId, review: module == 'review', module: module);
  }

  Future<void> show(String action,
      {AgentFocus? focus, BroadcastKind kind = BroadcastKind.step}) async {
    if (!visual) return;
    _ensureOnStage(focus?.module);
    _step++;
    writeAgentPresence(
      dataDir: dataDir,
      taskId: taskId,
      presence: AgentPresence(
        holder: holder,
        at: DateTime.now(),
        action: action,
        step: _step,
        kind: kind,
        focus: focus,
      ),
    );
    // 连着没人应就不再等：界面没开着的话，每步干等一个超时——
    // 一条命令报五步就白耗 25 秒，而人根本不在看
    if (_unanswered >= _giveUpAfter) return;

    waitedCount++;
    final shown = await waitForAck(
      dataDir: dataDir,
      taskId: taskId,
      step: _step,
      timeout: stepTimeout,
    );
    if (shown) {
      _unanswered = 0;
      return;
    }
    _unanswered++;
    AppLog.info('界面没跟上第 $_step 步（可能没开着），照常往下跑');
    if (_unanswered == _giveUpAfter) {
      AppLog.info('界面连着 $_giveUpAfter 步没回应，后面几步不再等它');
    }
  }

  /// 心跳：长活儿（配音、导出）每隔一会儿报一次，让界面知道它还在
  void heartbeat(String action,
      {AgentFocus? focus, BroadcastKind kind = BroadcastKind.step}) {
    if (!visual) return;
    // 配音、导出这类活儿一跑几分钟，中途人可能自己退出去了——
    // 心跳也要确认现场，不然「回来看看」就再也回不来
    _ensureOnStage(focus?.module, throttle: true);
    writeAgentPresence(
      dataDir: dataDir,
      taskId: taskId,
      presence: AgentPresence(
        holder: holder,
        at: DateTime.now(),
        action: action,
        step: _step,
        kind: kind,
        focus: focus,
      ),
    );
  }

  /// 报一句「我在干什么」——**两种模式都写**。
  ///
  /// 静默模式下人也可能正开着这一页：他至少该知道有东西在动他的任务，
  /// 而不是眼看着数据自己变。可视模式下等同 [heartbeat]（顺带确认现场）。
  ///
  /// 有了它，调用方不必再各写一遍「可视走 stage、静默裸写 presence」——
  /// 那个重复此前散在四处，每多一处就多一个漏掉焦点的机会。
  void note(String action,
      {AgentFocus? focus, BroadcastKind kind = BroadcastKind.step}) {
    if (visual) return heartbeat(action, focus: focus, kind: kind);
    writeAgentPresence(
      dataDir: dataDir,
      taskId: taskId,
      presence: AgentPresence(
        holder: holder,
        at: DateTime.now(),
        action: action,
        step: _step,
        kind: kind,
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

  Future<void> _launchApp({String? module}) async {
    if (_appLaunched) return;
    _appLaunched = true;
    try {
      // 「去哪个任务」走唤醒文件而不是 --args：启动参数只在冷启动时生效，
      // app 已经在跑时会被静默丢弃（`open` 命令那边真机撞到过——再点一次
      // 只是把窗口调到前台，什么都不发生）。文件冷热启动一条路
      _ensureOnStage(module);
      final failure = await launchApp(run: _run, exists: appExists);
      if (failure != null) {
        AppLog.warn('拉起 app 失败（可视模式退化成静默）：$failure');
      }
    } catch (e) {
      AppLog.warn('拉起 app 失败（可视模式退化成静默）：$e');
    }
  }
}

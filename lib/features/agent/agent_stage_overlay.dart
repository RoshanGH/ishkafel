import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/agent_broadcast.dart';
import '../../core/storage/agent_presence.dart';
import '../settings/settings_providers.dart';
import 'agent_broadcast_bar.dart';
import 'broadcast_scope.dart';
import 'presence_slots.dart';
import 'visual_pace.dart';

/// 全局的 Agent 播报层：**套在整个 app 外面**，Agent 走到哪它跟到哪。
///
/// 为什么是全局而不是每个页面各接一份：Agent 会跨模块走（新建任务 →
/// 编导台 → 找镜头 → 导出），播报得一路跟下去。各页面各画各的，
/// 切页面时播报就断了——而那恰恰是人最需要看的时候。
///
/// **节流点在这里，不在 Agent 那头**：每条播报至少停 [minHold] 才回执，
/// Agent 收到回执才走下一步。所以「慢下来让人看清」是界面在控节奏，
/// 而不是让 Agent 空睡——这也是当初定的原则：节奏由界面决定，不猜时间。
class AgentStageOverlay extends ConsumerStatefulWidget {
  final Widget child;

  /// 每条播报至少停多久。0.5 秒是「看清一行字」的下限
  final Duration minHold;

  const AgentStageOverlay({
    super.key,
    required this.child,
    this.minHold = visualStepDwell,
  });

  @override
  ConsumerState<AgentStageOverlay> createState() => _AgentStageOverlayState();
}

class _AgentStageOverlayState extends ConsumerState<AgentStageOverlay> {
  Timer? _poll;
  AgentBroadcast _broadcast = AgentBroadcast.empty;
  String? _holder;

  /// 正在被操作的那条任务的编号
  int? _actingSeq;

  /// 正在播的这条是什么时候上屏的——够 [minHold] 了才回执
  DateTime? _shownAt;

  /// 已经回执到第几步，别重复回
  final Map<String, int> _acked = {};

  @override
  void initState() {
    super.initState();
    // 500ms 与心跳同量级：跟得上手，也不吃 CPU
    _poll = Timer.periodic(visualPollInterval, (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// 任务的短编号（#9 那种）。读不到就返回 null——播报少一句话不要紧，
  /// 但不能因为读盘失败把整条播报卡住
  int? _seqOf(Directory dataDir, String? taskId) {
    if (taskId == null || taskId == globalPresenceSlot) return null;
    try {
      final f = File('${dataDir.path}/tasks/$taskId.json');
      if (!f.existsSync()) return null;
      final raw = jsonDecode(f.readAsStringSync());
      return raw is Map && raw['seq'] is int ? raw['seq'] as int : null;
    } catch (_) {
      return null;
    }
  }

  void _tick() {
    if (!mounted) return;
    final dataDir = ref.read(dataDirProvider);
    if (dataDir == null) return;

    // 全局槽 + 当前正在被操作的任务：Agent 可能在任一处报进度。
    // **取心跳最新的那条**，不是遇到第一个就停——目录顺序是文件系统给的，
    // 撞上一个陈旧的槽就会把真正在干活的那条挡住
    final slots = <String>{globalPresenceSlot, ...presenceTaskIds(dataDir)};
    AgentPresence? live;
    String? liveSlot;
    for (final slot in slots) {
      final p = readAgentPresence(dataDir: dataDir, taskId: slot);
      if (p == null) continue;
      if (live == null || p.at.isAfter(live.at)) {
        live = p;
        liveSlot = slot;
      }
    }

    if (live == null) {
      if (_holder != null) {
        // 收工：把最后一条标成做完，停一下再收走——
        // 「唰」地消失会让人怀疑刚才是不是看错了
        setState(() {
          _broadcast = _broadcast.finish();
          _holder = null;
        });
        Timer(const Duration(milliseconds: 1200), () {
          if (mounted && _holder == null) {
            setState(() => _broadcast = AgentBroadcast.empty);
          }
        });
      }
      return;
    }

    // 它在动哪条任务——人正看着的不一定就是它在动的那条
    _actingSeq =
        liveSlot == globalPresenceSlot ? null : _seqOf(dataDir, liveSlot);

    final action = live.action;
    final before = _broadcast.lines.length;
    final after = _broadcast.push(action);
    if (after.lines.length != before ||
        (after.lines.isNotEmpty &&
            _broadcast.lines.isNotEmpty &&
            after.lines.last.text != _broadcast.lines.last.text)) {
      setState(() {
        _broadcast = after;
        _holder = live!.holder;
        _shownAt = DateTime.now();
      });
    } else if (_holder != live.holder) {
      setState(() => _holder = live!.holder);
    }

    // 够时间了才回执：Agent 靠它决定什么时候走下一步
    final shown = _shownAt;
    if (liveSlot != null &&
        live.step > 0 &&
        (_acked[liveSlot] ?? -1) < live.step &&
        shown != null &&
        DateTime.now().difference(shown) >= widget.minHold) {
      _acked[liveSlot] = live.step;
      writeAgentAck(dataDir: dataDir, taskId: liveSlot, step: live.step);
    }
  }

  /// 哪些任务上可能有人在干活。只看 presence 目录里现成的文件，
  /// 不去翻整个任务库——这是每 300ms 跑一次的循环
  @override
  Widget build(BuildContext context) => Stack(children: [
        widget.child,
        AgentBroadcastBar(
            broadcast: _broadcast,
            holder: _holder,
            // 人正看着的不一定是它在动的那条：两个会话各干各的时，
            // 屏幕上写着「Agent 正在操作」而动的是别的任务
            scopeLabel: broadcastScopeLabel(actingTaskSeq: _actingSeq)),
      ]);
}

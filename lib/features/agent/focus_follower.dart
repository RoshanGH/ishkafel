import 'dart:io';

import '../../core/storage/agent_presence.dart';

/// 每一步至少在眼前停这么久。
///
/// **可视化是做给人看的**：Agent 一秒能跑完的事，人眼跟不上。这个值先定在
/// 这儿，按真机观感再调——重点是有这么个下限，而不是让界面一闪而过。
const Duration focusStepMinDwell = Duration(milliseconds: 700);

/// Agent 这一步在看哪儿、在干什么。
///
/// 这是**界面跟随的唯一依据**：`AgentFocus` 里的字段（哪个单元、哪一镜、
/// 该展开哪个面板）早就定义好了，但界面一直没读过它——于是可视模式的实际
/// 观感是「软件弹出来、跳到任务、底部滚一行字，界面什么都不动」，
/// 人看到的还是「Agent 在后台改数据、界面显示结果」。
class FocusStep {
  /// 第几步。Agent 每上报一次递增，界面展示完回执这个号
  final int step;

  /// 正在做什么，人话
  final String action;

  final String module;
  final int? unitIndex;
  final int? shotIndex;
  final int lineIndex;
  final int? materialId;
  final AgentPanel panel;

  const FocusStep({
    required this.step,
    required this.action,
    required this.module,
    required this.lineIndex,
    required this.panel,
    this.unitIndex,
    this.shotIndex,
    this.materialId,
  });

  /// 是不是还停在同一个地方。
  ///
  /// 同一个位置重复上报（心跳）不该让界面反复重建——那会让选中框闪、
  /// 滚动位置跳，人反而看不清
  bool sameSpotAs(FocusStep other) =>
      module == other.module &&
      unitIndex == other.unitIndex &&
      shotIndex == other.shotIndex &&
      lineIndex == other.lineIndex &&
      materialId == other.materialId &&
      panel == other.panel;
}

/// 读当前这一步；Agent 不在场、心跳停了、还没定位到具体位置时返回 null。
///
/// 返回 null 时界面**什么都不做**——人自己在操作时界面乱跳比不跳更糟。
FocusStep? readFocusStep({
  required Directory dataDir,
  required String taskId,
  DateTime? now,
}) {
  final presence =
      readAgentPresence(dataDir: dataDir, taskId: taskId, now: now);
  final focus = presence?.focus;
  if (presence == null || focus == null) return null;
  return FocusStep(
    step: presence.step,
    action: presence.action,
    module: focus.module,
    lineIndex: focus.lineIndex,
    unitIndex: focus.unitIndex,
    shotIndex: focus.shotIndex,
    materialId: focus.materialId,
    panel: focus.panel,
  );
}

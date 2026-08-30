import 'dart:ui';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/storage/agent_broadcast.dart';

/// Agent 干活时贴在底部的**播报条**。
///
/// 为什么做成全局一层而不是每个页面各画一条：Agent 会跨模块走
/// （新建任务 → 编导台 → 找镜头 → 导出），播报得跟着它一路走下去。
/// 各页面各画各的，切页面时播报就断了——而那恰恰是人最需要看的时候。
///
/// 视觉上的几条决定：
/// - **压在内容之上、不挤走内容**：毛玻璃浮层，人还能看清界面在变什么
/// - **最新的一条在最下**，往上依次变淡：视线自然落在底部，像聊天记录
/// - **只有最新一条在走**，前面的打勾变灰——一眼看出走到哪儿了
/// - **三类播报一眼分得开**（见 [BroadcastKind]）：进度是流水账，
///   判断是「它为什么改主意了」，发现问题是「人可能要当场喊停」。
///   混成一种样式的话，最该被看见的那一条会跟着流水账一起划过去
/// - 不拦点击：播报只是让人看见，不该挡住人接手
class AgentBroadcastBar extends StatelessWidget {
  final AgentBroadcast broadcast;

  /// 谁在干活（'Agent'）。没有就不显示
  final String? holder;

  /// 干的是哪条任务——**人正看着的不一定就是它在动的那条**。
  /// null = 就在眼前这条上干，不用啰嗦（见 [broadcastScopeLabel]）
  final String? scopeLabel;

  const AgentBroadcastBar({
    super.key,
    required this.broadcast,
    this.holder,
    this.scopeLabel,
  });

  @override
  Widget build(BuildContext context) {
    if (holder == null || broadcast.lines.isEmpty) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.82),
                border: const Border(
                    top: BorderSide(color: AppColors.border, width: 0.5)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _title(),
                  const SizedBox(height: AppSpacing.xs),
                  for (var i = 0; i < broadcast.lines.length; i++)
                    _line(broadcast.lines[i],
                        depth: broadcast.lines.length - 1 - i),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title() => Row(children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
              strokeWidth: 1.6, color: AppColors.accentBlue),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
            scopeLabel == null
                ? '$holder 正在操作，请稍候'
                : '$holder 正在操作 $scopeLabel，请稍候',
            key: const Key('broadcast-title'),
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary)),
        const SizedBox(width: AppSpacing.sm),
        const Text('这期间界面是只读的',
            style: TextStyle(
                fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
      ]);

  /// 这一类用什么颜色说话。
  ///
  /// 只在**判断**和**发现问题**上用色，进度保持原样——三类都上色的话
  /// 整条栏花得像圣诞树，等于一类都没突出。
  static Color _colorOf(BroadcastLine line) => switch (line.kind) {
        // 发现问题：橙色。这是「人可能要当场喊停」的一条，
        // 走过去了也不变灰——人回头要找得到它
        BroadcastKind.warning => AppColors.orange,
        // 判断：蓝色。它很值钱（人正是靠看懂它的想法才敢放手），
        // 但出现得频繁，用比警告克制一档的颜色
        BroadcastKind.judgement => AppColors.accentBlueLight,
        BroadcastKind.step =>
          line.done ? AppColors.textSecondary : AppColors.textPrimary,
      };

  /// 这一类前面摆什么符号
  static Widget _markOf(BroadcastLine line) => switch (line.kind) {
        BroadcastKind.warning => const Icon(Icons.report_problem_outlined,
            size: 11, color: AppColors.orange),
        BroadcastKind.judgement => const Icon(Icons.lightbulb_outline,
            size: 11, color: AppColors.accentBlueLight),
        BroadcastKind.step => line.done
            ? const Icon(Icons.check, size: 11, color: AppColors.green)
            : const Text('▸',
                style: TextStyle(
                    fontSize: AppFontSize.micro,
                    color: AppColors.accentBlueLight)),
      };

  Widget _line(BroadcastLine line, {required int depth}) {
    // 越旧越淡，但不淡到看不清——人可能正想回头确认上一步做了什么。
    // 发现问题的那条不跟着变淡：人走开一会儿回来，要找的就是它
    final opacity = line.kind == BroadcastKind.warning
        ? 1.0
        : (1.0 - depth * 0.18).clamp(0.4, 1.0);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Opacity(
        opacity: opacity,
        child: Row(children: [
          SizedBox(width: 16, child: _markOf(line)),
          Expanded(
            child: Text(
              line.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppFontSize.caption,
                height: 1.4,
                color: _colorOf(line),
                fontWeight: line.kind == BroadcastKind.warning
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 空脚本的起步引导：回答「从哪里开始」。
///
/// 两条路对应脚本的两个来源（设计稿问题①）：上传成片提取 / 手写。
/// 视觉上对标 Final Cut / 剪映的新建面板——克制、居中、两张等宽卡，
/// hover 有反馈，主推路径有蓝色语汇但不喧哗。
class StartGuide extends StatelessWidget {
  final bool canExtract;
  final VoidCallback onExtract;
  final VoidCallback onWrite;

  const StartGuide({
    super.key,
    required this.canExtract,
    required this.onExtract,
    required this.onWrite,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 顶部图形：双层圆角容器做出「App 图标」质感，不用一张孤零零的小图标
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.accentBlue.withValues(alpha: 0.22),
                  AppColors.accentBlue.withValues(alpha: 0.06),
                ],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: AppColors.accentBlue.withValues(alpha: 0.25)),
            ),
            child: const Icon(Icons.edit_note,
                size: 26, color: AppColors.accentBlueLight),
          ),
          const SizedBox(height: AppSpacing.lg),
          const Text('写下脚本，长出成片',
              style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                  color: AppColors.textPrimary)),
          const SizedBox(height: AppSpacing.sm),
          const Text('台词写一行，配音、镜头、字幕都从这一行长出来',
              style: TextStyle(
                  fontSize: AppFontSize.emphasis,
                  color: AppColors.textSecondary,
                  height: 1.5)),
          const SizedBox(height: AppSpacing.xxl),
          Row(mainAxisSize: MainAxisSize.min, children: [
            _GuideCard(
              cardKey: const ValueKey('director-guide-extract'),
              icon: Icons.movie_outlined,
              title: '用成片提取',
              description: canExtract
                  ? '上传一条参考成片\n自动识别台词，一句一行'
                  : '需要先配置 AI 服务\n（语音识别）',
              action: '上传视频',
              accent: true,
              badge: '推荐',
              enabled: canExtract,
              onTap: onExtract,
            ),
            const SizedBox(width: AppSpacing.lg),
            _GuideCard(
              cardKey: const ValueKey('director-guide-write'),
              icon: Icons.keyboard_alt_outlined,
              title: '从空白开始写',
              description: '在左栏逐行写台词\n回车新起一行，空行是画面行',
              action: '开始写',
              accent: false,
              enabled: true,
              onTap: onWrite,
            ),
          ]),
        ]),
      ),
    );
  }
}

class _GuideCard extends StatefulWidget {
  final Key cardKey;
  final IconData icon;
  final String title;
  final String description;
  final String action;
  final bool accent;
  final String? badge;
  final bool enabled;
  final VoidCallback onTap;

  const _GuideCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.description,
    required this.action,
    required this.accent,
    this.badge,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_GuideCard> createState() => _GuideCardState();
}

class _GuideCardState extends State<_GuideCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final live = widget.enabled;
    final lit = _hovered && live;
    return MouseRegion(
      cursor: live ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: widget.cardKey,
        onTap: live ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: 224,
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, AppSpacing.lg),
          decoration: BoxDecoration(
            color: lit ? AppColors.surfaceCard : AppColors.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
                color: lit
                    ? (widget.accent
                        ? AppColors.accentBlue.withValues(alpha: 0.7)
                        : AppColors.textTertiary.withValues(alpha: 0.5))
                    : AppColors.border),
            boxShadow: lit
                ? [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 18,
                        offset: const Offset(0, 6)),
                  ]
                : const [],
          ),
          child: Column(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: (widget.accent && live
                        ? AppColors.accentBlue
                        : AppColors.textTertiary)
                    .withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(AppRadius.md + 2),
              ),
              child: Icon(widget.icon,
                  size: 20,
                  color: widget.accent && live
                      ? AppColors.accentBlueLight
                      : AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(widget.title,
                  style: TextStyle(
                      fontSize: AppFontSize.emphasis,
                      fontWeight: FontWeight.w600,
                      color: live
                          ? AppColors.textPrimary
                          : AppColors.textTertiary)),
              if (widget.badge != null && live) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.accentBlue.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(widget.badge!,
                      style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accentBlueLight)),
                ),
              ],
            ]),
            const SizedBox(height: AppSpacing.sm),
            Text(widget.description,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary,
                    height: 1.6)),
            const SizedBox(height: AppSpacing.lg),
            // 伪按钮：告诉用户这张卡点下去会发生什么动作
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: 6),
              decoration: BoxDecoration(
                color: widget.accent && live
                    ? (lit
                        ? AppColors.accentBlue
                        : AppColors.accentBlue.withValues(alpha: 0.85))
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: widget.accent && live
                    ? null
                    : Border.all(
                        color: lit
                            ? AppColors.textSecondary
                            : AppColors.border),
              ),
              child: Text(widget.action,
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      fontWeight: FontWeight.w600,
                      color: widget.accent && live
                          ? Colors.white
                          : (live
                              ? AppColors.textPrimary
                              : AppColors.textTertiary))),
            ),
          ]),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// 设置分区里的一张卡（设计稿的 `.setcard`）
class SettingsCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const SettingsCard({super.key, this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final heading = title;
    // 外面必须包一层 Align：ListView 给的是**紧**的横向约束，
    // Container 自己的 maxWidth 会被 enforce 掉，卡片照样铺满整屏。
    // Align 把约束放松成 loose，maxWidth 才真正生效。
    //
    // 卡片自己**靠左**：居中的话，它和同一页里的说明文字、按钮
    // （那些是靠左的）会错开半截。整页内容作为一个整体居中，
    // 这件事在 [SettingsPage] 那一层做。
    return Align(
      alignment: Alignment.topLeft,
      child: _card(heading),
    );
  }

  Widget _card(String? heading) => Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 640),
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (heading != null) ...[
            Text(heading,
                style: const TextStyle(
                    fontSize: AppFontSize.emphasis,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary)),
            const SizedBox(height: AppSpacing.sm),
          ],
          ...children,
        ],
      ));
}

/// 「键 —— 值 + 操作」一行（设计稿的 `.setrow`）
class SettingsRow extends StatelessWidget {
  final String label;

  /// 值文本；为 null 时用 [content] 自定义右侧
  final String? value;
  final Widget? content;
  final Color? valueColor;

  /// 行尾操作（如「重试」「复制」）
  final Widget? trailing;

  const SettingsRow({
    super.key,
    required this.label,
    this.value,
    this.content,
    this.valueColor,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 84,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textSecondary)),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: content ??
                  SelectableText(
                    value ?? '—',
                    style: TextStyle(
                        fontSize: AppFontSize.body,
                        height: 1.5,
                        color: valueColor ?? AppColors.textPrimary),
                  ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ],
          ],
        ),
      );
}

/// 状态圆点 + 文字（绿=正常、橙=需要处理）
class StatusDot extends StatelessWidget {
  final bool ok;
  final String text;

  const StatusDot({super.key, required this.ok, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppColors.green : AppColors.orange;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(text,
            style: const TextStyle(
                fontSize: AppFontSize.body, color: AppColors.textPrimary)),
      ],
    );
  }
}

/// 分区内的说明文字：解释「为什么」与「接下来做什么」
class SettingsNote extends StatelessWidget {
  final String text;
  final Color? color;

  const SettingsNote(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Text(text,
            style: TextStyle(
                fontSize: AppFontSize.caption,
                height: 1.6,
                color: color ?? AppColors.textTertiary)),
      );
}

/// 读取失败的统一呈现：一句中文 + 一个真的能再试一次的按钮
class SettingsErrorBlock extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const SettingsErrorBlock(
      {super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(message,
                style: const TextStyle(
                    fontSize: AppFontSize.body,
                    height: 1.6,
                    color: AppColors.textPrimary)),
          ),
          const SizedBox(width: AppSpacing.md),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      );
}

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/export_spec.dart';
import '../../core/script/skipped_lines_summary.dart';
import '../export/export_options_panel.dart';

/// 脚本成片的导出设置：只出一条片子，但规格该选还得选——
/// 分辨率/帧率/码率/编码/格式与其他模块同一套面板（ExportOptionsPanel），
/// 「预计大小」随选择实时算。确认返回选好的规格；取消返回 null
Future<ExportSpec?> showScriptExportDialog(
  BuildContext context, {
  required ExportSpec initial,
  required int durationMs,
  required int lineCount,

  /// 没进这一版的行 → 原因（0 起下标）。空表示一句都没落下
  Map<int, String> skipped = const {},
}) =>
    showDialog<ExportSpec>(
      context: context,
      builder: (_) => _ScriptExportDialog(
        initial: initial,
        durationMs: durationMs,
        lineCount: lineCount,
        skipped: skipped,
      ),
    );

class _ScriptExportDialog extends StatefulWidget {
  final ExportSpec initial;
  final int durationMs;
  final int lineCount;

  /// 没进这一版的行 → 原因。**必须在这儿也说一遍**：中栏那行橙字是
  /// 编排时看的，人点开导出对话框就是在做「就导这个」的决定，
  /// 不该要求他记得刚才屏幕别处写过什么（2026-09-10 真机走查：
  /// 脚本 4 句、只有 1 句挑了镜头，对话框只写「1 句 · 3.2 秒」，
  /// 另外 3 句去哪了一个字都没有）
  final Map<int, String> skipped;

  const _ScriptExportDialog({
    required this.initial,
    required this.durationMs,
    required this.lineCount,
    required this.skipped,
  });

  @override
  State<_ScriptExportDialog> createState() => _ScriptExportDialogState();
}

class _ScriptExportDialogState extends State<_ScriptExportDialog> {
  late ExportSpec _spec = widget.initial;

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('导出成片',
            style: TextStyle(fontSize: AppFontSize.title)),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      '${widget.lineCount} 句 · '
                      '${(widget.durationMs / 1000).toStringAsFixed(1)} 秒',
                      style: const TextStyle(
                          fontSize: AppFontSize.caption,
                          color: AppColors.textTertiary)),
                  if (widget.skipped.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      key: const Key('script-export-skipped'),
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: AppColors.orange.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        '这一版里少了几句：\n'
                        '${summarizeSkippedLines(widget.skipped)}',
                        style: const TextStyle(
                            fontSize: AppFontSize.caption,
                            color: AppColors.orange,
                            height: 1.5),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                  ExportOptionsPanel(
                    spec: _spec,
                    onSpecChanged: (s) => setState(() => _spec = s),
                    // 脚本成片只出一条：没有「导出哪几条」的选择
                    totalCombos: 1,
                    pickCount: null,
                    onPickCountChanged: (_) {},
                    durationMs: widget.durationMs,
                  ),
                ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('script-export-confirm'),
            onPressed: () => Navigator.of(context).pop(_spec),
            child: const Text('开始导出'),
          ),
        ],
      );
}

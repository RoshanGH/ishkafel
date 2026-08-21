import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/export/export_spec.dart';
import '../export/export_options_panel.dart';

/// 脚本成片的导出设置：只出一条片子，但规格该选还得选——
/// 分辨率/帧率/码率/编码/格式与其他模块同一套面板（ExportOptionsPanel），
/// 「预计大小」随选择实时算。确认返回选好的规格；取消返回 null
Future<ExportSpec?> showScriptExportDialog(
  BuildContext context, {
  required ExportSpec initial,
  required int durationMs,
  required int lineCount,
}) =>
    showDialog<ExportSpec>(
      context: context,
      builder: (_) => _ScriptExportDialog(
        initial: initial,
        durationMs: durationMs,
        lineCount: lineCount,
      ),
    );

class _ScriptExportDialog extends StatefulWidget {
  final ExportSpec initial;
  final int durationMs;
  final int lineCount;

  const _ScriptExportDialog({
    required this.initial,
    required this.durationMs,
    required this.lineCount,
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

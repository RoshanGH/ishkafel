import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/update/release_manifest.dart';
import '../../core/update/update_service.dart';

/// 更新对话框：**从哪儿点都是这一个**。
///
/// 主界面顶栏那个「有新版本」和设置页里的更新卡片都走它——同一件事两处
/// 各写一套，迟早一处改了另一处没改（这个项目已经栽过三次）。
Future<void> showUpdateDialog(
  BuildContext context, {
  required ReleaseManifest release,
  UpdateService? service,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDialog(release: release, service: service),
    );

class _UpdateDialog extends StatefulWidget {
  final ReleaseManifest release;
  final UpdateService? service;
  const _UpdateDialog({required this.release, this.service});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  late final UpdateService _service = widget.service ?? UpdateService();
  UpdateState _state = const UpdateIdle();

  bool get _busy => _state is UpdateDownloading || _state is UpdateInstalling;

  Future<void> _go() async {
    await _service.install(
      widget.release,
      onState: (s) {
        if (mounted) setState(() => _state = s);
      },
      // 替换脚本已经接手：这个进程必须退出，它才能动这个 app
      onExit: () async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        exit(0);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.release;
    return AlertDialog(
      title: Text('新版本 ${r.version}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(
                  r.notes.trim().isEmpty ? '（这一版没写更新说明）' : r.notes.trim(),
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.6,
                      color: AppColors.textPrimary),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
                '要下载 ${(r.sizeBytes / 1024 / 1024).toStringAsFixed(0)} MB。'
                '装好会自动重启软件——正在跑的分析、配音、导出会被打断，'
                '正在编辑的内容请先收尾。',
                style: const TextStyle(
                    fontSize: AppFontSize.micro,
                    height: 1.5,
                    color: AppColors.textTertiary)),
            if (_state case UpdateDownloading(:final ratio)) ...[
              const SizedBox(height: AppSpacing.md),
              // 每一次等待都要有交代：带分母的进度，不是一个转圈
              Text('正在下载（${(ratio * 100).toStringAsFixed(0)}%）',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
              const SizedBox(height: AppSpacing.xs),
              LinearProgressIndicator(value: ratio, minHeight: 3),
            ],
            if (_state is UpdateInstalling) ...[
              const SizedBox(height: AppSpacing.md),
              const Text('正在校验并安装，马上重启…',
                  style: TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary)),
              const SizedBox(height: AppSpacing.xs),
              const LinearProgressIndicator(minHeight: 3),
            ],
            if (_state case UpdateFailed(:final message)) ...[
              const SizedBox(height: AppSpacing.md),
              // 失败要给原因和重试入口，不能只写日志
              Text('没更新成：$message',
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: AppColors.orange)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('以后再说'),
        ),
        FilledButton(
          key: const ValueKey('update-now'),
          onPressed: _busy ? null : _go,
          child: Text(_state is UpdateFailed ? '再试一次' : '现在更新'),
        ),
      ],
    );
  }
}

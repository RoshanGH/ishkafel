import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/export/export_plan.dart';
import '../../core/export/export_runner.dart';
import '../../core/models/semantic_unit.dart';
import '../../core/replacement/replacement_plan.dart';

/// 造一个能干活的导出器（真实 ffmpeg + 真实下载）。
/// 缺省为 null，由 main.dart 按数据目录装配；测试注入假实现。
typedef ExportRunnerFactory = ExportRunner Function(String taskId);

final exportRunnerFactoryProvider =
    Provider<ExportRunnerFactory?>((ref) => null);

/// 矩阵导出面板：先看清要导出什么，再开始；跑起来之后有进度、有失败清单。
Future<void> showExportDialog(
  BuildContext context, {
  required String taskId,
  required String taskName,
  required String sourcePath,
  required List<SemanticUnit> units,
  required List<UnitReplacement> replacements,
  BgmPlan bgm = BgmPlan.empty,
  Map<int, String> voiceAudio = const {},
  required Directory outputDir,
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportDialog(
        taskId: taskId,
        taskName: taskName,
        sourcePath: sourcePath,
        units: units,
        replacements: replacements,
        bgm: bgm,
        voiceAudio: voiceAudio,
        outputDir: outputDir,
      ),
    );

class _ExportDialog extends ConsumerStatefulWidget {
  final String taskId;
  final String taskName;
  final String sourcePath;
  final List<SemanticUnit> units;
  final List<UnitReplacement> replacements;
  final BgmPlan bgm;
  final Map<int, String> voiceAudio;
  final Directory outputDir;

  const _ExportDialog({
    required this.taskId,
    required this.taskName,
    required this.sourcePath,
    required this.units,
    required this.replacements,
    required this.bgm,
    required this.voiceAudio,
    required this.outputDir,
  });

  @override
  ConsumerState<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<_ExportDialog> {
  bool _running = false;
  (int done, int total, String what)? _progress;
  List<ExportOutcome>? _results;
  String? _failure;

  late final List<ExportCombination> _combos = ExportPlanner.enumerate(
      units: widget.units, replacements: widget.replacements);

  Future<void> _start() async {
    final factory = ref.read(exportRunnerFactoryProvider);
    if (factory == null) {
      setState(() => _failure = '未检测到 ffmpeg，无法合成成片。装好后重启应用再试');
      return;
    }
    setState(() {
      _running = true;
      _failure = null;
      _progress = (0, _combos.length, '准备中');
    });
    try {
      final results = await factory(widget.taskId).exportAll(
        sourcePath: widget.sourcePath,
        units: widget.units,
        replacements: widget.replacements,
        outputDir: widget.outputDir,
        bgm: widget.bgm,
        voiceAudio: widget.voiceAudio,
        onProgress: (d, t, w) {
          if (mounted) setState(() => _progress = (d, t, w));
        },
      );
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _failure = '导出失败：$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('矩阵导出'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _summary(),
                if (_failure case final f?) ...[
                  const SizedBox(height: AppSpacing.md),
                  Text(f,
                      style: const TextStyle(
                          color: AppColors.red, fontSize: AppFontSize.body)),
                ],
                if (_progress case final p? when _running) ...[
                  const SizedBox(height: AppSpacing.md),
                  LinearProgressIndicator(
                      value: p.$2 == 0 ? null : p.$1 / p.$2,
                      color: AppColors.accentBlue,
                      backgroundColor: AppColors.surface),
                  const SizedBox(height: AppSpacing.xs),
                  Text('${p.$1}/${p.$2} · ${p.$3}',
                      key: const Key('export-progress'),
                      style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: AppFontSize.caption)),
                ],
                if (_results case final r?) ...[
                  const SizedBox(height: AppSpacing.md),
                  _resultList(r),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('export-close'),
            onPressed: _running ? null : () => Navigator.of(context).pop(),
            child: Text(_results == null ? '取消' : '关闭'),
          ),
          if (_results == null)
            FilledButton(
              key: const Key('export-start'),
              onPressed: _running || _combos.isEmpty ? null : _start,
              child: Text(_running ? '导出中…' : '开始导出'),
            ),
        ],
      );

  Widget _summary() {
    final replaced = _combos.where((c) => c.replacedCount > 0).length;
    final seconds =
        (_combos.isEmpty ? 0 : _combos.first.durationMs) / 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('共 ${_combos.length} 条成片 · 每条约 ${seconds.toStringAsFixed(1)}s',
            key: const Key('export-summary'),
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppFontSize.emphasis,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: AppSpacing.xs),
        // 「有几条其实跟原片一样」要说在前面：用户按条数付出的是等待时间
        Text(
          replaced == _combos.length
              ? '每条都至少换掉了一段画面'
              : '其中 ${_combos.length - replaced} 条与原片画面相同（没有为任何一段选替换素材）',
          style: const TextStyle(
              color: AppColors.textTertiary, fontSize: AppFontSize.caption),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text('导出到：${widget.outputDir.path}',
            style: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.caption)),
        const SizedBox(height: AppSpacing.xs),
        const Text('画面来自替换素材，声音沿用原片（换过音色的用生成的配音）',
            style: TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro)),
      ],
    );
  }

  Widget _resultList(List<ExportOutcome> results) {
    final failed = results.where((r) => !r.ok).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          failed.isEmpty
              ? '${results.length} 条全部导出完成'
              : '成功 ${results.length - failed.length} 条，失败 ${failed.length} 条',
          key: const Key('export-result'),
          style: TextStyle(
              color: failed.isEmpty ? AppColors.green : AppColors.orange,
              fontSize: AppFontSize.body,
              fontWeight: FontWeight.w600),
        ),
        // 失败的要逐条点名并带原因，否则用户只能一条条自己找
        for (final f in failed)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text('第 ${f.index} 条：${f.failure}',
                style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.micro,
                    height: 1.4)),
          ),
      ],
    );
  }
}

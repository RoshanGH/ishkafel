import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/log/app_log.dart';
import '../../../core/storage/cache_usage.dart';
import '../settings_providers.dart';
import '../settings_widgets.dart';

/// 缓存管理分区。
///
/// 只清理**孤儿**产物——任务已删、文件还在的那部分。在用任务的封面与波形
/// 一律不动：清掉它们会让现有任务打开时空空如也，而用户点的按钮上写的是
/// 「清理缓存」，不该有这种后果。
class CacheSection extends ConsumerStatefulWidget {
  const CacheSection({super.key});

  @override
  ConsumerState<CacheSection> createState() => _CacheSectionState();
}

class _CacheSectionState extends ConsumerState<CacheSection> {
  bool _purging = false;

  @override
  Widget build(BuildContext context) {
    final usage = ref.watch(cacheUsageProvider);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        usage.when(
          loading: () => const SettingsCard(
              children: [SettingsRow(label: '占用', value: '统计中…')]),
          error: (_, _) => SettingsCard(children: [
            SettingsErrorBlock(
                message: '读取缓存占用失败，请点「重试」。',
                onRetry: () => ref.invalidate(cacheUsageProvider)),
          ]),
          data: _body,
        ),
      ],
    );
  }

  Widget _body(CacheUsage usage) {
    final reclaimable = usage.reclaimableBytes;
    return SettingsCard(
      title: '本地缓存',
      children: [
        SettingsRow(label: '总占用', value: formatBytes(usage.totalBytes)),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(label: '封面', value: formatBytes(usage.coversBytes)),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(
            label: '分析产物',
            value: '${formatBytes(usage.workBytes)} · 共 ${usage.fileCount} 个文件'),
        const Divider(height: 1, color: AppColors.border),
        SettingsRow(
          label: '可回收',
          value: reclaimable > 0
              ? '${formatBytes(reclaimable)}（${usage.orphanCount} 个残留文件）'
              : '0 B',
          valueColor: reclaimable > 0 ? AppColors.orange : null,
        ),
        const SizedBox(height: AppSpacing.sm),
        SettingsNote(reclaimable > 0
            ? '这些是已删除任务留下的中间产物（音频、抽帧图），删掉不影响任何现有任务。'
            : '当前所有中间产物都属于现有任务，没有可回收的空间。'
                '删除任务时它的产物会被一并清理。'),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('settings-purge-cache'),
            onPressed: reclaimable > 0 && !_purging ? () => _confirm(usage) : null,
            child: Text(_purging ? '清理中…' : '清理残留产物'),
          ),
        ),
      ],
    );
  }

  /// 删除不可逆，先确认；确认框里必须写清楚会删掉什么、有多少
  Future<void> _confirm(CacheUsage usage) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理残留产物'),
        content: Text(
          '将删除 ${usage.orphanCount} 个文件，释放约 ${formatBytes(usage.reclaimableBytes)}。\n\n'
          '这些文件属于已被删除的任务，现有任务的封面与波形不受影响。删除后无法撤销。',
          style: const TextStyle(fontSize: AppFontSize.body, height: 1.6),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清理')),
        ],
      ),
    );
    if (ok != true) return;
    await _purge();
  }

  Future<void> _purge() async {
    setState(() => _purging = true);
    try {
      final freed = await ref.read(cachePurgeProvider)();
      ref.invalidate(cacheUsageProvider);
      _toast(freed > 0 ? '已清理，释放 ${formatBytes(freed)}' : '没有可清理的文件');
    } catch (e) {
      // 原始异常只进日志，界面给人话
      AppLog.warn('清理缓存失败：$e');
      ref.invalidate(cacheUsageProvider);
      _toast('清理未完成，部分文件可能正在被占用。请稍后再试。');
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

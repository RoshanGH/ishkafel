import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/bgm_plan.dart';
import '../../core/script/script_doc.dart';
import '../workbench/bgm_picker_sheet.dart';

/// 配乐段管理（行区间铺设）：每段 = 起止行 + 曲子 + 音量。
/// 相邻两段同一首曲子时播放连续不重头。左栏拖选/色带是后续升级，
/// 这里先把「多段多曲」的能力立起来。
Future<List<ScriptBgmSegment>?> showBgmSegmentsSheet(
  BuildContext context, {
  required ScriptDoc doc,
  required List<int> projectIds,
}) =>
    showDialog<List<ScriptBgmSegment>>(
      context: context,
      builder: (_) => _BgmSegmentsDialog(doc: doc, projectIds: projectIds),
    );

class _BgmSegmentsDialog extends StatefulWidget {
  final ScriptDoc doc;
  final List<int> projectIds;

  const _BgmSegmentsDialog({required this.doc, required this.projectIds});

  @override
  State<_BgmSegmentsDialog> createState() => _BgmSegmentsDialogState();
}

class _BgmSegmentsDialogState extends State<_BgmSegmentsDialog> {
  late final List<ScriptBgmSegment> _segments = [...widget.doc.bgmSegments];

  int get _lineCount => widget.doc.lines.length;

  Future<void> _addOrEdit({int? editIndex}) async {
    final existing = editIndex == null ? null : _segments[editIndex];
    var startLine = existing?.startLine ?? 0;
    var endLine = existing?.endLine ?? (_lineCount - 1);
    // 第一步：定行区间
    final range = await showDialog<(int, int)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: Text(editIndex == null ? '铺到哪几行？' : '改行区间'),
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('第 ', style: TextStyle(fontSize: AppFontSize.body)),
            DropdownButton<int>(
              key: const ValueKey('bgm-start-line'),
              value: startLine,
              items: [
                for (var i = 0; i < _lineCount; i++)
                  DropdownMenuItem(value: i, child: Text('${i + 1}')),
              ],
              onChanged: (v) => setInner(() {
                startLine = v!;
                if (endLine < startLine) endLine = startLine;
              }),
            ),
            const Text(' 行 ～ 第 ',
                style: TextStyle(fontSize: AppFontSize.body)),
            DropdownButton<int>(
              key: const ValueKey('bgm-end-line'),
              value: endLine,
              items: [
                for (var i = startLine; i < _lineCount; i++)
                  DropdownMenuItem(value: i, child: Text('${i + 1}')),
              ],
              onChanged: (v) => setInner(() => endLine = v!),
            ),
            const Text(' 行', style: TextStyle(fontSize: AppFontSize.body)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消')),
            FilledButton(
                key: const ValueKey('bgm-range-ok'),
                onPressed: () =>
                    Navigator.of(context).pop((startLine, endLine)),
                child: const Text('下一步')),
          ],
        ),
      ),
    );
    if (range == null || !mounted) return;
    // 第二步：选曲（复用工作台的配乐面板；带上现有选择与音量）
    final choice = await showBgmPicker(
      context,
      rangeMs: 15000,
      rangeLabel: '第 ${range.$1 + 1}~${range.$2 + 1} 行',
      canClear: false,
      projectIds: widget.projectIds,
      initialVolume: existing?.volume ?? BgmSegment.defaultVolume,
      initialMaterials: [if (existing != null) existing.material],
    );
    if (choice is! BgmPicked || choice.materials.isEmpty || !mounted) return;
    final material = choice
        .materials[choice.previewIndex.clamp(0, choice.materials.length - 1)];
    final seg = ScriptBgmSegment(
      startLine: range.$1,
      endLine: range.$2,
      material: material,
      volume: choice.volume,
    );
    setState(() {
      if (editIndex == null) {
        _segments.add(seg);
      } else {
        _segments[editIndex] = seg;
      }
      _segments.sort((a, b) => a.startLine.compareTo(b.startLine));
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      title: const Text('配乐', style: TextStyle(fontSize: AppFontSize.title)),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('按行区间铺曲子；相邻两段同一首时播放连续不重头',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.md),
          if (_segments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Text('还没有配乐段',
                  style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: AppColors.textTertiary)),
            )
          else
            for (var i = 0; i < _segments.length; i++) _segmentRow(i),
          const SizedBox(height: AppSpacing.sm),
          TextButton.icon(
            key: const ValueKey('bgm-add-segment'),
            onPressed: _addOrEdit,
            icon: const Icon(Icons.add, size: 14),
            label: const Text('加一段配乐'),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          key: const ValueKey('bgm-segments-ok'),
          onPressed: () =>
              Navigator.of(context).pop(List<ScriptBgmSegment>.from(_segments)),
          child: const Text('就这样'),
        ),
      ],
    );
  }

  Widget _segmentRow(int i) {
    final seg = _segments[i];
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.xs),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Text('第 ${seg.startLine + 1}~${seg.endLine + 1} 行',
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                color: AppColors.textSecondary,
                fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(seg.material.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: AppFontSize.body, color: AppColors.textPrimary)),
        ),
        Text('${(seg.volume * 100).round()}%',
            style: const TextStyle(
                fontSize: AppFontSize.micro, color: AppColors.textTertiary)),
        IconButton(
          key: ValueKey('bgm-edit-$i'),
          visualDensity: VisualDensity.compact,
          iconSize: 14,
          onPressed: () => _addOrEdit(editIndex: i),
          icon: const Icon(Icons.edit_outlined, color: AppColors.textSecondary),
          tooltip: '改这一段',
        ),
        IconButton(
          key: ValueKey('bgm-remove-$i'),
          visualDensity: VisualDensity.compact,
          iconSize: 14,
          onPressed: () => setState(() => _segments.removeAt(i)),
          icon: const Icon(Icons.close, color: AppColors.textSecondary),
          tooltip: '删掉这一段',
        ),
      ]),
    );
  }
}

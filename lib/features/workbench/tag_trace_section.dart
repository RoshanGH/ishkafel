import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/models/tag_trace.dart';
import 'inspector_widgets.dart';

/// 打标结果 + 打标过程量。
///
/// 打标是个黑箱：标签不对时，用户既分不清是「送去的画面没取对」还是「模型
/// 理解错了」，也无从判断这份标签是不是编辑之前打的。所以这里把三样东西都
/// 摊开——当前标签、画面描述、以及产生它们的那次调用喂了什么、原样回了
/// 什么。过程量默认收起：它是排障时才看的，摊开会把真正要看的属性挤下去。
class TagTraceSection extends StatefulWidget {
  final String title;
  final List<String> tags;

  /// 标签是编辑前打的，还没重打
  final bool tagsStale;

  /// 画面描述（视觉层才有）。它同时是「按画面描述检索素材」的检索键，
  /// 因此值得单独露出来让用户核对。
  final String? description;

  final TagTrace? trace;

  const TagTraceSection({
    super.key,
    required this.title,
    required this.tags,
    this.tagsStale = false,
    this.description,
    this.trace,
  });

  @override
  State<TagTraceSection> createState() => _TagTraceSectionState();
}

class _TagTraceSectionState extends State<TagTraceSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => inspectorCard([
        Row(
          children: [
            inspectorLabel(widget.title),
            const Spacer(),
            if (widget.tagsStale) const _StaleBadge(),
          ],
        ),
        _tags(),
        if (widget.description case final d? when d.trim().isNotEmpty) ...[
          inspectorLabel('画面描述'),
          Text(d,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: AppFontSize.caption,
                  height: 1.5)),
        ],
        if (widget.trace case final t?) ...[
          _expandToggle(),
          if (_expanded) _TraceDetail(trace: t),
        ],
      ]);

  /// 标签**按维度分行**显示。
  ///
  /// 一个镜头可能同时有场景/镜头类别/动作/外壳四个维度的标签，堆成一排
  /// chips 就看不出「场景判成了什么、动作判成了什么」——而这恰恰是用户
  /// 判断标签对不对时要看的。拿不到维度信息（旧数据）时退回一排。
  Widget _tags() {
    if (widget.tags.isEmpty) {
      return const Text('未打标',
          style: TextStyle(
              color: AppColors.textTertiary, fontSize: AppFontSize.caption));
    }
    final byDimension = widget.trace?.tagsByDimension ?? const {};
    if (byDimension.isEmpty) return inspectorTagChips(widget.tags);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in byDimension.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(e.key,
                      style: const TextStyle(
                          color: AppColors.textTertiary,
                          fontSize: AppFontSize.caption)),
                ),
                Expanded(
                  child: e.value.isEmpty
                      // 这个维度一个都没打上，要说出来——不显示的话用户
                      // 会以为这个维度压根没送进去
                      ? const Text('—',
                          style: TextStyle(
                              color: AppColors.textTertiary,
                              fontSize: AppFontSize.caption))
                      : inspectorTagChips(e.value),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _expandToggle() => InkWell(
        key: const Key('trace-expand'),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            children: [
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: AppColors.textTertiary),
              const SizedBox(width: AppSpacing.xs),
              Text(_expanded ? '收起打标过程' : '查看打标过程',
                  style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption)),
            ],
          ),
        ),
      );
}

class _StaleBadge extends StatelessWidget {
  const _StaleBadge();

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('trace-stale-badge'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: AppColors.orange.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text('待重打',
            style: TextStyle(
                color: AppColors.orange, fontSize: AppFontSize.micro)),
      );
}

/// 过程量明细：喂进去什么、词表多大、模型原样回了什么
class _TraceDetail extends StatelessWidget {
  final TagTrace trace;
  const _TraceDetail({required this.trace});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (trace.sampledAtMs.isNotEmpty) ...[
            _line('送去理解', '${trace.sampledAtMs.length} 帧 · '
                '${trace.sampledAtMs.map(_seconds).join(' / ')}'),
            _frames(),
          ],
          if (trace.textInput case final t? when t.isNotEmpty)
            _line('送去理解', t),
          if (trace.vocabularyGroups.isNotEmpty)
            _line('受控词表',
                '${trace.vocabularyGroups.join('、')} · ${trace.vocabularySize} 个词'),
          // 标签不对时，「喂进去的约束是什么」往往才是问题所在
          if (trace.prompt case final p? when p.isNotEmpty)
            _line('打标约束', p),
          if (trace.at case final at?) _line('打标时间', _stamp(at)),
          if (trace.rawReply case final r? when r.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            inspectorLabel('模型原样回复'),
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(r,
                  style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: AppFontSize.micro,
                      fontFamily: 'Menlo',
                      height: 1.5)),
            ),
          ],
        ],
      );

  /// 采样帧的缩略图。文件可能已被清理（用户清过缓存），缺了就不画那一张，
  /// 不摆一个破图图标——那只会让人以为打标出错了。
  Widget _frames() {
    final files = [
      for (final path in trace.framePaths)
        if (File(path).existsSync()) path,
    ];
    if (files.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        height: 56,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: files.length,
          separatorBuilder: (_, _) => const SizedBox(width: 4),
          itemBuilder: (_, i) => ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.file(File(files[i]),
                height: 56, fit: BoxFit.cover, errorBuilder: (_, _, _) =>
                    const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            inspectorLabel(label),
            Text(value,
                style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.caption,
                    height: 1.4)),
          ],
        ),
      );

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  static String _stamp(DateTime at) {
    final l = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}

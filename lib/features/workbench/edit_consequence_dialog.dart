import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/edit_consequence.dart';

/// 用户对「改完之后怎么办」的回答
class EditConsequenceChoice {
  final bool clearCandidates;
  final bool retag;

  const EditConsequenceChoice({
    required this.clearCandidates,
    required this.retag,
  });

  bool get nothingToDo => !clearCandidates && !retag;
}

/// 改完切分之后问一句：要不要清掉这几个单元挑好的素材、要不要重新打标。
///
/// 不自动做也不默不作声：自动清会让用户白挑一遍，默不作声则会让他拿着一份
/// 对不上画面的标签继续往下走。默认值按改动幅度给（见 [EditConsequence]），
/// 改得少时两项都不勾——一路回车就是「什么都不用动」。
Future<EditConsequenceChoice?> showEditConsequenceDialog(
  BuildContext context,
  EditConsequence consequence,
) =>
    showDialog<EditConsequenceChoice>(
      context: context,
      builder: (ctx) => _EditConsequenceDialog(consequence: consequence),
    );

class _EditConsequenceDialog extends StatefulWidget {
  final EditConsequence consequence;
  const _EditConsequenceDialog({required this.consequence});

  @override
  State<_EditConsequenceDialog> createState() => _EditConsequenceDialogState();
}

class _EditConsequenceDialogState extends State<_EditConsequenceDialog> {
  late bool _clear = widget.consequence.clearCandidatesByDefault;
  late bool _retag = widget.consequence.retagByDefault;

  String get _who {
    final names =
        widget.consequence.unitIndexes.map((i) => 'U${i + 1}').toList();
    // 超过五个就不逐个念了：一长串 U 编号读不出重点
    if (names.length > 5) return '${names.take(5).join('、')} 等 ${names.length} 个';
    return names.join('、');
  }

  String get _magnitude => widget.consequence.structural
      ? '切分结构变了（拆分/合并），原来的素材与标签多半已经对不上'
      : '改动幅度约 ${(widget.consequence.maxChangedRatio * 100).round()}%';

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surfaceRaised,
        title: const Text('改完之后要连带处理吗？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('刚才改到了 $_who。$_magnitude。',
                style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: AppFontSize.body)),
            const SizedBox(height: AppSpacing.md),
            _Option(
              key: const Key('consequence-clear'),
              value: _clear,
              onChanged: (v) => setState(() => _clear = v),
              title: '清除这几个单元已选的替换素材',
              subtitle: '画面变了，原来挑的素材可能对不上；不清就保持现状',
            ),
            _Option(
              key: const Key('consequence-retag'),
              value: _retag,
              onChanged: (v) => setState(() => _retag = v),
              title: '重新打标',
              subtitle: '标记为待重打并立即送去打标；不重打就沿用现有标签',
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('consequence-skip'),
            onPressed: () => Navigator.of(context).pop(
                const EditConsequenceChoice(clearCandidates: false, retag: false)),
            child: const Text('都不用'),
          ),
          FilledButton(
            key: const Key('consequence-confirm'),
            onPressed: () => Navigator.of(context).pop(
                EditConsequenceChoice(clearCandidates: _clear, retag: _retag)),
            child: const Text('按上面处理'),
          ),
        ],
      );
}

class _Option extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;

  const _Option({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: AppFontSize.body)),
                    Text(subtitle,
                        style: const TextStyle(
                            color: AppColors.textTertiary,
                            fontSize: AppFontSize.caption)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

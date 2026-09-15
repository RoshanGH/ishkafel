import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/editing/edit_consequence.dart';
import '../../core/replacement/replacement_plan.dart';

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
  EditConsequence consequence, {
  List<UnitReplacement> replacements = const [],
}) =>
    showDialog<EditConsequenceChoice>(
      context: context,
      builder: (ctx) => _EditConsequenceDialog(
          consequence: consequence, replacements: replacements),
    );

class _EditConsequenceDialog extends StatefulWidget {
  final EditConsequence consequence;

  /// 用来算「这一下会取消掉几条素材」——只说「清除已选的替换素材」，
  /// 人不知道自己要丢多少东西（他问过：点了之后影响范围有哪些）
  final List<UnitReplacement> replacements;

  const _EditConsequenceDialog(
      {required this.consequence, this.replacements = const []});

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

  /// 这几个单元一共挑了几条素材——整体替换的和每一镜的都算
  int get _pickedCount {
    var n = 0;
    for (final i in widget.consequence.unitIndexes) {
      if (i < 0 || i >= widget.replacements.length) continue;
      final r = widget.replacements[i];
      n += r.wholeCandidateIds.length;
      for (final ids in r.shotCandidateIds.values) {
        n += ids.length;
      }
    }
    return n;
  }

  /// 「清除替换素材」这一条到底会动什么。**把数字说出来**
  String get _clearSubtitle {
    final n = _pickedCount;
    if (n == 0) {
      return '$_who 现在没挑任何素材，勾不勾都一样';
    }
    return '把 $_who 挑的 $n 条素材全部取消（整体替换的、每一镜的都算），'
        '这几个单元回到「保留原片」。不勾就原样留着';
  }

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
            const SizedBox(height: 2),
            // **先把范围钉死**：人最想知道的是「会不会动到别的地方」
            Text('下面两项只作用在 $_who 上，别的单元一个都不碰。',
                key: const Key('consequence-scope'),
                style: const TextStyle(
                    color: AppColors.textTertiary,
                    fontSize: AppFontSize.caption)),
            const SizedBox(height: AppSpacing.md),
            _Option(
              key: const Key('consequence-clear'),
              value: _clear,
              onChanged: (v) => setState(() => _clear = v),
              title: '取消 $_who 已挑的素材',
              subtitle: _clearSubtitle,
            ),
            _Option(
              key: const Key('consequence-retag'),
              value: _retag,
              onChanged: (v) => setState(() => _retag = v),
              title: '给 $_who 重新打标',
              subtitle: '点完就送去云端逐个看图打标，要花钱、要等一会儿。'
                  '不勾就先标成「待重打」，沿用现有标签，以后再打',
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

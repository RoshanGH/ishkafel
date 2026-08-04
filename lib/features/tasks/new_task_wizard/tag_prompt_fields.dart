import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/models/tag_group_ref.dart';

/// 每个已选标签组后面跟一个「打标约束」输入框。
///
/// 为什么按**组**而不是按层给一段：一个层可能选了四个组（场景 / 镜头类别 /
/// 动作 / 外壳），它们各是一个维度、口径完全不同——合成一段写，模型分不清
/// 哪句约束管哪个维度。
///
/// 新建向导与「标签组设置」两处共用：向导里选完组当场就能写，第一次打标就
/// 用得上；不然只能等打完一遍、进任务再改一遍重打。
class TagPromptFields extends StatefulWidget {
  /// 区分两层，用于 Key（同一个组可能同时出现在两层里）
  final String layer;

  final List<TagGroupRef> groups;

  /// 任一输入框变化时上抛带上新约束的整份列表
  final ValueChanged<List<TagGroupRef>> onChanged;

  const TagPromptFields({
    super.key,
    required this.layer,
    required this.groups,
    required this.onChanged,
  });

  @override
  State<TagPromptFields> createState() => _TagPromptFieldsState();
}

class _TagPromptFieldsState extends State<TagPromptFields> {
  /// 组 id → 输入框控制器。切换选择时复用，用户已经写好的约束不会因为
  /// 多选了一个组就被清掉。
  final _controllers = <int, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(TagGroupRef g) => _controllers
      .putIfAbsent(g.id, () => TextEditingController(text: g.prompt ?? ''));

  void _emit() {
    widget.onChanged([
      for (final g in widget.groups) g.withPrompt(_promptOf(g)),
    ]);
  }

  /// 空白视为「没写」：存一个空串会让提示词里多出一行空的「本维度约束：」，
  /// 模型只会去猜它省略了什么。
  String? _promptOf(TagGroupRef g) {
    final text = _controllers[g.id]?.text.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final g in widget.groups)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: TextField(
                key: Key('tag-prompt-${widget.layer}-${g.id}'),
                controller: _controllerFor(g),
                minLines: 1,
                maxLines: 4,
                onChanged: (_) => _emit(),
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: AppFontSize.caption),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: AppColors.surface,
                  border: const OutlineInputBorder(),
                  labelText: '「${g.name}」的打标约束（可留空）',
                  labelStyle: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.caption),
                  hintText: '按这个组词表的粒度来写。例：只判断画面里出现的'
                      '具体位置或物体表面，不要判断整体空间',
                  hintStyle: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: AppFontSize.micro),
                ),
              ),
            ),
        ],
      );
}

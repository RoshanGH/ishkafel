import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';

/// 一层一个「打标约束」输入框。
///
/// 为什么按**层**而不是按组：一层选四个组（场景 / 镜头类别 / 动作 / 外壳）时，
/// 那四个组是同一次打标里的四个维度——维度分开是为了让模型每个维度各答一份，
/// 而用户想约束的是「这一层要怎么判」这件事本身。每组各挂一个输入框，界面上
/// 会随着多选冒出四个框，用户得把同一句话抄四遍。
///
/// 新建向导与「标签组设置」两处共用：向导里选完组当场就能写，第一次打标就
/// 用得上；不然只能等打完一遍、进任务再改一遍重打。
class TagPromptField extends StatefulWidget {
  /// 区分两层，用于 Key
  final String layer;

  /// 输入框上的说明，例如「台词语义单元」
  final String layerLabel;

  final String value;
  final ValueChanged<String> onChanged;

  const TagPromptField({
    super.key,
    required this.layer,
    required this.layerLabel,
    required this.value,
    required this.onChanged,
  });

  @override
  State<TagPromptField> createState() => _TagPromptFieldState();
}

class _TagPromptFieldState extends State<TagPromptField> {
  late final _controller = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: TextField(
          key: Key('tag-prompt-${widget.layer}'),
          controller: _controller,
          minLines: 1,
          maxLines: 4,
          // 首尾空白视为没写：存一个空串会让提示词里多出一行空的
          // 「打标约束：」，模型只会去猜它省略了什么
          onChanged: (v) => widget.onChanged(v.trim()),
          style: const TextStyle(
              color: AppColors.textPrimary, fontSize: AppFontSize.caption),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppColors.surface,
            border: const OutlineInputBorder(),
            labelText: '${widget.layerLabel}的打标约束（可留空）',
            labelStyle: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.caption),
            hintText: '这一层怎么判由你定。例：只判断画面里出现的具体位置或'
                '物体表面，不要判断整体空间',
            hintStyle: const TextStyle(
                color: AppColors.textTertiary, fontSize: AppFontSize.micro),
          ),
        ),
      );
}

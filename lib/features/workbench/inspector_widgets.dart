import 'dart:async';
import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_typography.dart';

/// InspectorPanel 的纯展示型辅助组件：不持有状态、不依赖 controller，
/// 只接收已经算好的文案/回调，从 inspector_panel.dart 中拆出以控制单文件行数。

Widget inspectorTitle(String text) => Text(
      text,
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: AppFontSize.body,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );

Widget inspectorLabel(String text) => Text(
      text,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: AppFontSize.body),
    );

Widget inspectorCard(List<Widget> children) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          children[i],
        ],
      ]),
    );

Widget inspectorInfoRow(String label, String value) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        inspectorLabel(label),
        Text(value,
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: AppFontSize.body,
                fontFeatures: [FontFeature.tabularFigures()])),
      ],
    );

/// 时间码步进行：[valueText] 由调用方预先用 formatTimecode 格式化好传入，
/// 本函数不关心 fps/ms 换算逻辑。[minusEnabled]/[plusEnabled] 为 false 时
/// 按钮降低透明度且不响应点击（首/末边界无对应边界可调）。
Widget inspectorTimeRow({
  required String label,
  required String valueText,
  required Key minusKey,
  required Key plusKey,
  required bool minusEnabled,
  required bool plusEnabled,
  required VoidCallback onMinus,
  required VoidCallback onPlus,
}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      inspectorLabel(label),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _stepButton(minusKey, '−', minusEnabled ? onMinus : null),
            const SizedBox(width: 6),
            Text(
              valueText,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: AppFontSize.caption,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
            const SizedBox(width: 6),
            _stepButton(plusKey, '＋', plusEnabled ? onPlus : null),
          ],
        ),
      ),
    ],
  );
}

Widget _stepButton(Key key, String glyph, VoidCallback? onTap) =>
    _RepeatingStepButton(buttonKey: key, glyph: glyph, onStep: onTap);

/// 帧步进按钮：点一下走一帧；**按住不放就连发快走**（按住 400ms 后
/// 每 60ms 一步）——逐帧对齐一个隔了几十帧的边界，让人一下一下点是折磨
class _RepeatingStepButton extends StatefulWidget {
  /// 挂在 GestureDetector 上（而不是本组件上）：既有测试与锁定 UI 都按
  /// 这个 key 探测「按钮是否可用」
  final Key buttonKey;
  final String glyph;
  final VoidCallback? onStep;

  const _RepeatingStepButton(
      {required this.buttonKey, required this.glyph, this.onStep});

  @override
  State<_RepeatingStepButton> createState() => _RepeatingStepButtonState();
}

class _RepeatingStepButtonState extends State<_RepeatingStepButton> {
  Timer? _holdDelay;
  Timer? _repeat;

  void _startHold() {
    // 按下先走一步（即点即有反馈），停 400ms 再进入连发——
    // 太快进入连发会让「想点一下」的人多走好几帧
    widget.onStep?.call();
    _holdDelay = Timer(const Duration(milliseconds: 400), () {
      _repeat = Timer.periodic(
          const Duration(milliseconds: 60), (_) => widget.onStep?.call());
    });
  }

  void _stopHold() {
    _holdDelay?.cancel();
    _repeat?.cancel();
    _holdDelay = null;
    _repeat = null;
  }

  @override
  void dispose() {
    _stopHold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onStep != null;
    return GestureDetector(
      key: widget.buttonKey,
      onTapDown: enabled ? (_) => _startHold() : null,
      onTapUp: (_) => _stopHold(),
      onTapCancel: _stopHold,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Text(widget.glyph,
            style: TextStyle(
                color: enabled
                    ? AppColors.textTertiary
                    : AppColors.textTertiary.withValues(alpha: 0.35),
                fontSize: AppFontSize.emphasis)),
      ),
    );
  }
}

Widget inspectorTagChips(List<String> tags) {
  if (tags.isEmpty) {
    return const Text('无标签',
        style: TextStyle(color: AppColors.textTertiary, fontSize: AppFontSize.caption));
  }
  return Wrap(
    spacing: 6,
    runSpacing: 6,
    children: tags
        .map((t) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.accentBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(t,
                  style: const TextStyle(
                      color: AppColors.accentBlueLight, fontSize: AppFontSize.micro)),
            ))
        .toList(growable: false),
  );
}

/// [onSplit]/[onMerge] 为 null 时按钮禁用（降透明度且不响应点击）——
/// 只读回看模式（评审 Important 1）下不允许拆分/合并已确认的切分结构。
Widget inspectorActionsRow({
  required String splitLabel,
  required String mergeLabel,
  required VoidCallback? onSplit,
  required VoidCallback? onMerge,
}) {
  return Row(
    children: [
      Expanded(
        child: _actionButton(
          key: const Key('inspector-split-btn'),
          label: splitLabel,
          onTap: onSplit,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _actionButton(
          key: const Key('inspector-merge-btn'),
          label: mergeLabel,
          onTap: onMerge,
        ),
      ),
    ],
  );
}

Widget _actionButton({
  required Key key,
  required String label,
  required VoidCallback? onTap,
}) {
  final enabled = onTap != null;
  return InkWell(
    key: key,
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style: TextStyle(
              color: enabled
                  ? AppColors.textPrimary
                  : AppColors.textPrimary.withValues(alpha: 0.35),
              fontSize: AppFontSize.body)),
    ),
  );
}

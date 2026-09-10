import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/subtitle/subtitle_style.dart';

/// 字幕样式面板（位置 / 字号 / 六色 / 衬底）。
/// 样式粒度是**句**：全局一套基调，个别句子需要时行级覆盖。
/// [allowApplyAll] 打开时多一个「应用到整片」——调好一句觉得整片都
/// 该这样，一键提升为全局默认。返回 (样式, 是否应用到整片)
///
/// [onPreview] **边调边推**：每动一下就把当下这套样式交出去，让预览跟着变。
/// 不推的话人只能凭那两个数字（「距底 21%」「23‰」）盲调，点完「就这样」
/// 才看得见结果，不对再开一次——用户原话：「现在能调整了，但是没法实时
/// 显示位置，有点在盲调的感觉」（2026-09-09 真机）。
///
/// 调用方拿到 [onPreview] 之后应当**只改内存、不落盘**，并且在拿到 null
/// （取消）时把样式退回原样——人点了取消就是不要，不能留在半路上。
///
/// **它是一块浮层，不是模态弹窗**（2026-09-09 真机，用户原话：「是我点
/// 字幕之后，你有一层遮罩，不是字幕的衬底」）。`showDialog` 会给整屏蒙一层
/// black54 并拦掉所有点击，而这套参数恰恰是照着画面判断的：
///
/// - 压暗了，挑颜色、看衬底盖没盖住原素材的字，全都不准；
/// - 拦住了，就没法把播放头挪到被替换的那一镜——而字幕只画在那儿，
///   人只能「关面板 → 拖时间线 → 再开面板」，正是他嫌烦的那个循环。
///
/// 代价是生命周期得自己管：面板还开着时页面被销毁的话，浮层会留在
/// Overlay 上。所以调用方要留住 [SubtitleStylePanel]，在 dispose 里
/// [SubtitleStylePanel.close] 兜一下。
SubtitleStylePanel showSubtitleStylePanel(BuildContext context,
    {required SubtitleStyle initial,
    bool allowApplyAll = false,
    ValueChanged<SubtitleStyle>? onPreview}) {
  final done = Completer<(SubtitleStyle, bool)?>();
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  var removed = false;
  void finish((SubtitleStyle, bool)? result) {
    if (removed) return;
    removed = true;
    entry.remove();
    if (!done.isCompleted) done.complete(result);
  }

  entry = OverlayEntry(
    builder: (_) => _SubtitleStylePanelLayer(
      initial: initial,
      allowApplyAll: allowApplyAll,
      onPreview: onPreview,
      onDone: finish,
    ),
  );
  overlay.insert(entry);
  return SubtitleStylePanel._(done.future, finish);
}

/// 开着的那块浮层。[done] 是人点了「就这样」/「取消」之后的结果，
/// [close] 是调用方销毁时的兜底（当作取消）
class SubtitleStylePanel {
  final Future<(SubtitleStyle, bool)?> done;
  final void Function((SubtitleStyle, bool)?) _finish;

  const SubtitleStylePanel._(this.done, this._finish);

  void close() => _finish(null);
}

/// 兼容旧调用与测试：等它关掉再返回
Future<(SubtitleStyle, bool)?> showSubtitleStyleSheet(BuildContext context,
        {required SubtitleStyle initial,
        bool allowApplyAll = false,
        ValueChanged<SubtitleStyle>? onPreview}) =>
    showSubtitleStylePanel(context,
            initial: initial,
            allowApplyAll: allowApplyAll,
            onPreview: onPreview)
        .done;

/// 浮层本体：**只有面板那一块拦点击**，其余地方原样透下去
class _SubtitleStylePanelLayer extends StatelessWidget {
  final SubtitleStyle initial;
  final bool allowApplyAll;
  final ValueChanged<SubtitleStyle>? onPreview;
  final void Function((SubtitleStyle, bool)?) onDone;

  const _SubtitleStylePanelLayer({
    required this.initial,
    required this.allowApplyAll,
    required this.onPreview,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) => Positioned(
        // 靠右居中摆一块卡片，画面在左边照常看得见。
        //
        // **不能套 Positioned.fill + IgnorePointer**：IgnorePointer 一挡，
        // 整棵子树都不参与命中测试，里面再套一个 `ignoring: false` 也救不回来
        // （面板自己就点不动了）。这里只给右边界和上下界，卡片有多宽就占多宽，
        // 而 [Center] 空白处本来就不命中——点击自然穿到底下的时间线上
        right: AppSpacing.xl,
        top: AppSpacing.lg,
        bottom: AppSpacing.lg,
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: _SubtitleStyleDialog(
                initial: initial,
                allowApplyAll: allowApplyAll,
                onPreview: onPreview,
                onDone: onDone),
          ),
        ),
      );
}

/// 六色（白/黄/橙/绿/蓝/粉），hex 不带 #
const subtitleColors = <(String, String)>[
  ('FFFFFF', '白'),
  ('FFD900', '黄'),
  ('FF9F0A', '橙'),
  ('30D158', '绿'),
  ('64A8FF', '蓝'),
  ('FF6482', '粉'),
];

class _SubtitleStyleDialog extends StatefulWidget {
  final SubtitleStyle initial;
  final bool allowApplyAll;
  final ValueChanged<SubtitleStyle>? onPreview;
  final void Function((SubtitleStyle, bool)?) onDone;
  const _SubtitleStyleDialog(
      {required this.initial,
      this.allowApplyAll = false,
      this.onPreview,
      required this.onDone});

  @override
  State<_SubtitleStyleDialog> createState() => _SubtitleStyleDialogState();
}

class _SubtitleStyleDialogState extends State<_SubtitleStyleDialog> {
  late double _bottomRatio = widget.initial.bottomRatio;
  late double _fontRatio = widget.initial.fontRatio;
  late String _colorHex = widget.initial.colorHex ?? 'FFFFFF';
  late SubtitlePreset _mask = switch (widget.initial.preset) {
    SubtitlePreset.whiteBox => SubtitlePreset.whiteBox,
    SubtitlePreset.blurBox => SubtitlePreset.blurBox,
    _ => SubtitlePreset.whiteOutline,
  };

  SubtitleStyle get _style => SubtitleStyle(
        bottomRatio: _bottomRatio,
        fontRatio: _fontRatio,
        colorHex: _colorHex == 'FFFFFF' ? null : _colorHex,
        preset: _mask,
      );

  /// 改一下就推一次给预览。**每一次都推**（含拖动途中的每一格）——
  /// 节流是调用方的事，它才知道重渲一段要多久
  void _change(VoidCallback apply) {
    setState(apply);
    widget.onPreview?.call(_style);
  }

  @override
  Widget build(BuildContext context) {
    // 一块靠右摆的卡片（**不是对话框**，见 [showSubtitleStylePanel]）：
    // 调字号、位置、颜色全靠看预览判断，居中的弹窗正好把画面盖住，
    // 而模态遮罩连画面的亮度都改了。右侧是属性栏，盖住它不影响这件事
    return Container(
      width: 360,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.border),
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('字幕样式', style: TextStyle(fontSize: AppFontSize.title)),
          const SizedBox(height: AppSpacing.sm),
          const Text('整片的字幕基调（没有单独调过的句子都按这套画）',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary)),
          const SizedBox(height: AppSpacing.lg),
          _row('位置', Slider(
            key: const ValueKey('subtitle-bottom'),
            value: _bottomRatio,
            min: 0.05,
            max: 0.5,
            activeColor: AppColors.accentBlue,
            onChanged: (v) => _change(() => _bottomRatio = v),
          ), trailing: '距底 ${(_bottomRatio * 100).round()}%'),
          // 字号连续可调（用户定的：横轴滑杆，平滑）
          _row('字号', Slider(
            key: const ValueKey('subtitle-font'),
            value: _fontRatio.clamp(0.018, 0.065),
            min: 0.018,
            max: 0.065,
            activeColor: AppColors.accentBlue,
            onChanged: (v) => _change(() => _fontRatio = v),
          ), trailing: '${(_fontRatio * 1000).round()}‰'),
          _row(
              '颜色',
              Row(children: [
                for (final (hex, name) in subtitleColors)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: Tooltip(
                      message: name,
                      child: InkWell(
                        key: ValueKey('subtitle-color-$hex'),
                        onTap: () => _change(() => _colorHex = hex),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(int.parse('FF$hex', radix: 16)),
                            border: Border.all(
                                color: _colorHex == hex
                                    ? AppColors.accentBlue
                                    : AppColors.border,
                                width: _colorHex == hex ? 2 : 1),
                          ),
                        ),
                      ),
                    ),
                  ),
              ])),
          _row(
              '衬底',
              Row(children: [
                for (final (preset, label) in const [
                  (SubtitlePreset.whiteOutline, '无'),
                  (SubtitlePreset.blurBox, '毛玻璃'),
                  (SubtitlePreset.whiteBox, '黑底条'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: ChoiceChip(
                      key: ValueKey('subtitle-mask-${preset.name}'),
                      label: Text(label,
                          style:
                              const TextStyle(fontSize: AppFontSize.caption)),
                      selected: _mask == preset,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => _change(() => _mask = preset),
                    ),
                  ),
              ]),
              trailing: switch (_mask) {
                SubtitlePreset.blurBox => '字幕背后磨砂',
                SubtitlePreset.whiteBox => '半透明黑底',
                _ => '描边无底',
              }),
          const SizedBox(height: AppSpacing.sm),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (widget.allowApplyAll)
              TextButton(
                key: const ValueKey('subtitle-apply-all'),
                onPressed: () => widget.onDone((_style, true)),
                child: const Text('应用到整片'),
              ),
            TextButton(
                onPressed: () => widget.onDone(null),
                child: const Text('取消')),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              key: const ValueKey('subtitle-confirm'),
              onPressed: () => widget.onDone((_style, false)),
              child: const Text('就这样'),
            ),
          ]),
      ]),
    );
  }

  Widget _row(String label, Widget child, {String? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Row(children: [
          SizedBox(
              width: 36,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: AppFontSize.caption,
                      color: AppColors.textSecondary))),
          Expanded(child: child),
          if (trailing != null)
            Text(trailing,
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textTertiary)),
        ]),
      );
}

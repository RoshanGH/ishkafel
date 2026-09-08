import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/material_audio.dart';
import 'inspector_widgets.dart';

/// 这一镜「保留素材原声」的开关与音量。
///
/// 视觉镜头替换换的是**画面**，那一段的口播照旧来自原片，所以候选素材自己的
/// 声音一直是被丢掉的。打开之后它作为**额外一层**叠回来——口播、素材原声、
/// 配乐三者同时响。要的通常是那个现场感：水声、喷雾声、环境音。
///
/// 三态而不是一个开关：**跟随全片 / 单独开 / 单独关**。「跟随」是 null，
/// 和「单独关」不是一回事——全片开着时，跟随等于开，而用户点「关」是要它
/// 真的闭嘴。少了这一态，人就没法在全片开着的前提下关掉个别镜头。
class MaterialAudioCard extends StatelessWidget {
  /// 全片打底设置
  final MaterialAudioSetting taskDefault;

  /// 这一镜的覆盖。null = 跟随全片
  final MaterialAudioMode? shotMode;
  final double? shotVolume;

  /// 这一镜换过素材没有。没换就没有「素材的声音」可言，整张卡片不出现
  final bool replaced;

  /// 换上来那条素材自己的语音转写。非空 = 它自己带口播，
  /// 保留原声会和台词打架——**提示但不拦**，有时候要的就是那句话
  final String? materialVoiceover;

  /// mode 传 null 表示改回「跟随全片」（把覆盖清掉）
  final void Function(MaterialAudioMode? mode, double? volume) onChanged;

  const MaterialAudioCard({
    super.key,
    required this.taskDefault,
    required this.replaced,
    required this.onChanged,
    this.shotMode,
    this.shotVolume,
    this.materialVoiceover,
  });

  MaterialAudioSetting get _effective => resolveMaterialAudio(
        taskDefault: taskDefault,
        shotMode: shotMode,
        shotVolume: shotVolume,
      );

  @override
  Widget build(BuildContext context) {
    if (!replaced) return const SizedBox.shrink();
    final effective = _effective;
    return inspectorCard([
      inspectorLabel('替换分镜的声音'),
      const SizedBox(height: 4),
      const Text('这一镜换成了别的素材，放它自己的哪一路声音',
          style: TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textTertiary)),
      const SizedBox(height: AppSpacing.sm),
      // **只摆四个档位**。「跟随全片」不是第五个选项——全片默认就是「不播放」，
      // 那时它和「不播放」按钮做的是同一件事，摆两个一模一样的东西人只会愣住。
      // 跟不跟随是个**状态**，用下面那个标记表示，回退路径也单给一条
      Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
        for (final m in MaterialAudioMode.values)
          _choice(
            key: ValueKey('material-audio-${m.name}'),
            label: m.label,
            // 没单独设过时，跟着全片的那一档也显示为选中——
            // 人要看的是「这一镜现在放什么」，而不是「我设过没有」
            selected: effective.mode == m,
            onTap: () => onChanged(m, shotVolume),
          ),
      ]),
      const SizedBox(height: AppSpacing.xs),
      if (shotMode == null)
        const Text('跟随全片',
            style: TextStyle(
                fontSize: AppFontSize.caption, color: AppColors.textTertiary))
      else
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('material-audio-unfollow'),
            onPressed: () => onChanged(null, null),
            style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: const Text('改回跟随全片',
                style: TextStyle(fontSize: AppFontSize.caption)),
          ),
        ),
      const SizedBox(height: 4),
      Text(effective.mode.hint,
          style: const TextStyle(
              fontSize: AppFontSize.caption,
              height: 1.5,
              color: AppColors.textTertiary)),
      if (effective.mode.audible) ...[
        const SizedBox(height: AppSpacing.sm),
        Row(children: [
          Text('音量 ${(effective.volume * 100).round()}%',
              style: const TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textSecondary)),
          Expanded(
            child: Slider(
              value: effective.volume,
              onChanged: (v) => onChanged(shotMode, v),
            ),
          ),
        ]),
        // 素材自己带口播、又选了会把那句话放出来的档位，才提醒。
        // 选了「背景声」正是为了避开这件事，这时再唠叨就是噪音
        if (_speechClash)
          const Text('这条素材自己带口播，放出来会和你的台词同时响——'
              '想要现场感可以改成「背景声」',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  height: 1.5,
                  color: AppColors.orange)),
      ],
    ]);
  }

  /// 素材自带口播、而这一档会把它放出来
  bool get _speechClash =>
      materialVoiceover != null &&
      materialVoiceover!.trim().isNotEmpty &&
      (_effective.mode == MaterialAudioMode.original ||
          _effective.mode == MaterialAudioMode.vocals);

  Widget _choice({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      ChoiceChip(
        key: key,
        label: Text(label,
            style: const TextStyle(fontSize: AppFontSize.caption)),
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        backgroundColor: AppColors.surfaceRaised,
        selectedColor: AppColors.accentBlue,
        side: const BorderSide(color: AppColors.border),
      );
}

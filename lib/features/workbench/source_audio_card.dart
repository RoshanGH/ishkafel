import 'package:flutter/material.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/audio/material_audio.dart';
import '../../core/audio/source_audio.dart';
import 'inspector_widgets.dart';

/// 这一镜「原片这一镜的声音」的档位与音量。
///
/// 成片的声音是两层：这一层（主轨，原片这一段）+ 替换素材那一层
/// （见 [MaterialAudioCard]）。两层各选各的，组合由人定——用户原话
/// （2026-09-10）：「很有可能我需要的是原片 S1 的口播和替换分镜的原声。
/// 只是我不想做这么定制化，我要把它拆成功能。」
///
/// ## 「自动」不是第五个档位，是「还没选过」
///
/// 没点过任何一档时走的是老行为：原混音照播，被配乐盖住时换成纯人声。
/// 直接把默认写死成「原声」的话，人什么都没动、铺了配乐的段落反而变差。
/// 一旦他点了任意一档，就完全按他选的来，冲突只提示不拦。
///
/// ## 只在换过素材的镜头上出现
///
/// 没换素材的镜头上没有可选的余地（用户原话：「如果没替换分镜，
/// 那连原片这一分镜的声音该怎么操作都不应该有」）。整段被整体替换、
/// 或者换过音色的单元同理——那两种情况下原片这一段的声音要么不存在、
/// 要么已经被生成的配音顶掉了。
class SourceAudioCard extends StatelessWidget {
  /// 全片打底
  final SourceAudioSetting taskDefault;

  /// 这一镜的覆盖。null = 跟随全片
  final MaterialAudioMode? shotMode;
  final double? shotVolume;

  /// 这一镜换过素材没有。没换就整张卡不出现
  final bool replaced;

  /// 这个单元换过音色：那一段的人声来自生成的配音，原片这一路无从取起。
  /// 卡片照出，但只写明原因、不给档位——藏起来的话人会以为功能没了
  final bool voiceSwapped;

  /// 这一句里还有哪几镜没换素材（`S2`、`S3`）。
  ///
  /// 一句台词常常跨好几镜：这一镜剥掉了原片现场音、旁边那一镜还是原混音，
  /// 同一句话说到一半背景音突然出现。**这类问题人听得出别扭却找不到原因**，
  /// 所以要点名说出来
  final List<String> unreplacedSiblings;

  /// 这条任务有没有分离好的人声/背景轨。没有的话选了要分离的档位会失败，
  /// 得先去「重新分离」
  final bool hasVocals;
  final bool hasBackground;

  /// 这一段的底片是一条**素材**（不是原片）。
  ///
  /// 那时这张卡调的是那条素材自己的声音——原片这一段根本不在成片里，
  /// 标签还写「原片」会让人以为调的是另一条声音
  final bool onMaterialBase;

  /// mode 传 null 表示改回「跟随全片」
  final void Function(MaterialAudioMode? mode, double? volume) onChanged;

  const SourceAudioCard({
    super.key,
    required this.taskDefault,
    required this.replaced,
    required this.onChanged,
    this.shotMode,
    this.shotVolume,
    this.voiceSwapped = false,
    this.unreplacedSiblings = const [],
    this.hasVocals = false,
    this.hasBackground = false,
    this.onMaterialBase = false,
  });

  SourceAudioSetting? get _effective => resolveSourceAudio(
        replaced: replaced,
        taskDefault: taskDefault,
        shotMode: shotMode,
        shotVolume: shotVolume,
      );

  /// 这一段的**底片**说人话叫什么：底片是原片就是「原片」，底片被固定成
  /// 一条素材就是「底片」——那时原片那一段的声音根本不在成片里，
  /// 还写「原片」会让人以为调的是另一条声音
  String get _whose => onMaterialBase ? '底片' : '原片';

  @override
  Widget build(BuildContext context) {
    if (!replaced) return const SizedBox.shrink();
    if (voiceSwapped) {
      return inspectorCard([
        inspectorLabel('$_whose这一镜的声音'),
        const SizedBox(height: 4),
        const Text('这个单元换过音色——那一段的人声来自生成的配音，'
            '原片这一路已经不在成片里了',
            key: Key('source-audio-voice-swapped'),
            style: TextStyle(
                fontSize: AppFontSize.caption,
                height: 1.5,
                color: AppColors.textTertiary)),
      ]);
    }
    final effective = _effective;
    final volume = effective?.volume ?? taskDefault.volume;
    return inspectorCard([
      inspectorLabel('$_whose这一镜的声音'),
      const SizedBox(height: 4),
      Text('这一镜换成了别的素材，$_whose这一段自己放哪一路声音',
          style: const TextStyle(
              fontSize: AppFontSize.caption, color: AppColors.textTertiary)),
      const SizedBox(height: AppSpacing.sm),
      Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
        for (final m in MaterialAudioMode.values)
          _choice(
            key: ValueKey('source-audio-${m.name}'),
            label: m.label,
            selected: effective?.mode == m,
            onTap: () => onChanged(m, shotVolume),
          ),
      ]),
      const SizedBox(height: AppSpacing.xs),
      if (effective == null)
        const Text('自动：原片这一段原样播；这一格铺了配乐就自动换成纯人声'
            '（否则老背景和新配乐两首曲子一起响）',
            key: Key('source-audio-auto'),
            style: TextStyle(
                fontSize: AppFontSize.caption,
                height: 1.5,
                color: AppColors.textTertiary))
      else ...[
        if (shotMode == null)
          const Text('跟随全片',
              style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: AppColors.textTertiary))
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('source-audio-unfollow'),
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
        Text(effective.mode!.sourceHint,
            style: const TextStyle(
                fontSize: AppFontSize.caption,
                height: 1.5,
                color: AppColors.textTertiary)),
        if (_stemMissing)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                '这条任务还没有分离好的${effective.mode == MaterialAudioMode.vocals ? '人声' : '背景音'}轨，'
                '预览会先放原混音，导出会被拦下——先点一下「重新分离」',
                key: const Key('source-audio-stem-missing'),
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.5,
                    color: AppColors.orange)),
          ),
        if (effective.mode!.audible) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(children: [
            Text('音量 ${(volume * 100).round()}%',
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    color: AppColors.textSecondary)),
            Expanded(
              child: Slider(
                value: volume,
                onChanged: (v) => onChanged(effective.mode, v),
              ),
            ),
          ]),
          // 预览走多轨 EDL，而 EDL 没法给某一段单独设音量——说清楚，
          // 别让人以为拖了没反应
          if (volume < 0.999)
            const Text('预览按满音量放，这个音量在导出时生效',
                key: Key('source-audio-volume-preview-note'),
                style: TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.5,
                    color: AppColors.textTertiary)),
        ],
        if (unreplacedSiblings.isNotEmpty && effective.mode!.needsSeparation)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
                '这一句里 ${unreplacedSiblings.join('、')} 没换素材，'
                '那几镜照旧是原混音——同一句话说到一半，背景音会突然变',
                key: const Key('source-audio-midsentence'),
                style: const TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.5,
                    color: AppColors.orange)),
          ),
      ],
    ]);
  }

  /// 选了要分离的档位，而那条轨还不在
  bool get _stemMissing {
    final mode = _effective?.mode;
    if (mode == MaterialAudioMode.vocals) return !hasVocals;
    if (mode == MaterialAudioMode.background) return !hasBackground;
    return false;
  }

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

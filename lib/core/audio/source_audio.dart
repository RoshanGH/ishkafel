/// 「原片这一镜的声音」——被替换掉画面的那一镜，**原片那一段自己放哪一路**。
///
/// 成片的声音一直是两层：主轨（原片这一镜的整条混音）+ 叠加层
/// （替换素材自己的声音，见 [MaterialAudioSetting]）。叠加层早就能拆成
/// 人声/背景，主轨却一直是个隐含的常量——只有被配乐盖住时才会自动换成
/// 纯人声。于是「要原片说的那句话 + 素材的现场音」这种再正常不过的组合
/// 做不出来。
///
/// 用户原话（2026-09-10）：「我需要把参考视频的声音也拆开。这样我就可以用
/// 替换分镜的原声，加上参考分镜的人声或者背景声，排列组合由我自己选。
/// 我不想做这么定制化，我要把它拆成功能。」
///
/// 所以主轨也用同一套四档（[MaterialAudioMode]），两层各选各的。
///
/// ## 「自动」是第五种状态，不是第五个档位
///
/// 没设过 = 自动 = 这个功能出现之前的行为：原混音照播，被配乐盖住时换成
/// 纯人声（否则老背景与新配乐两首曲子一起响）。默认值要是直接写死「原声」，
/// 用户什么都没动、铺了配乐的段落声音反而变差。
/// **一旦他点了任意一档，就完全按他选的来**，冲突只提示不拦。
///
/// ## 只作用于换过素材的镜头
///
/// 没换素材的镜头照旧走自动那条路，界面上连控件都不出现——那种镜头上
/// 「原片的声音」就是它本来的声音，没有可选的余地。
library;

import 'material_audio.dart';

/// 「原片这一镜的声音」的设置：放哪一路 + 多大声。
class SourceAudioSetting {
  /// null = 自动（见类文档）
  final MaterialAudioMode? mode;

  /// 压到原始音量的几成（0~1）。原片这一路是**主体**，默认满音量——
  /// 和叠加层默认 25% 正好相反，那一层是垫在口播底下的
  final double volume;

  static const double defaultVolume = 1.0;

  /// 什么都没设：跟今天的行为一模一样
  static const SourceAudioSetting auto = SourceAudioSetting();

  const SourceAudioSetting({this.mode, double volume = defaultVolume})
      : volume = volume < 0
            ? 0
            : volume > 1
                ? 1
                : volume;

  /// 交给用户决定过没有
  bool get isAuto => mode == null;

  SourceAudioSetting copyWith({MaterialAudioMode? mode, double? volume}) =>
      SourceAudioSetting(
          mode: mode ?? this.mode, volume: volume ?? this.volume);

  /// 回到自动。[copyWith] 的 `??` 语义做不到（传 null 等于「不改」）
  SourceAudioSetting toAuto() => SourceAudioSetting(volume: volume);

  Map<String, dynamic> toJson() => {
        if (mode != null) 'mode': mode!.name,
        'volume': volume,
      };

  factory SourceAudioSetting.fromJson(Map<String, dynamic>? json) {
    if (json == null) return auto;
    return SourceAudioSetting(
      mode: MaterialAudioMode.byName(json['mode'] as String?),
      volume: (json['volume'] as num?)?.toDouble() ?? defaultVolume,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SourceAudioSetting &&
      other.mode == mode &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(mode, volume);
}

/// 这一镜的原片声音**最终怎么放**。
///
/// 返回 null = **自动**，也就是走这个功能出现之前那条路（原混音；被配乐
/// 盖住时换成纯人声）。三种情况都会落到自动：
/// - 这一镜没换素材（[replaced] 为假）——那种镜头上没有可选的余地；
/// - 镜头没单独设，全片打底也是自动；
/// - 镜头明确设了「跟随全片」而全片是自动。
///
/// 镜头的 `null` 是「跟随全片」，全片的 `null` 才是「自动」——两级的
/// null 不是一个意思。
SourceAudioSetting? resolveSourceAudio({
  required bool replaced,
  required SourceAudioSetting taskDefault,
  MaterialAudioMode? shotMode,
  double? shotVolume,
}) {
  if (!replaced) return null;
  final mode = shotMode ?? taskDefault.mode;
  if (mode == null) return null;
  return SourceAudioSetting(
      mode: mode, volume: shotVolume ?? taskDefault.volume);
}

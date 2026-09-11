import '../models/semantic_unit.dart';
/// 替换掉的这一镜，**放它自己的哪一路声音**。
///
/// 视觉镜头替换换的是画面，那一段的口播照旧来自原片。素材自己的声音默认是
/// 丢掉的，但常常正是要的东西——所以给四档，而不是「要/不要」两选一：
///
/// 素材的声音本来就能拆成两路（跟给原片分人声用的是同一套工具）。拆开之后
/// 「要现场感」和「要那句话」就成了两件事，不必二选一地互相牵连：
/// 素材自己带口播时选 [background]，现场音全在，别人说的话被分掉。
enum MaterialAudioMode {
  /// 不放。只有台词语义单元自己的声音（默认，也是这个功能出现之前的行为）
  none('不播放', '只有原片这一段的声音'),

  /// 只放素材里的人声（要它说的那句话）
  vocals('人声', '素材里说话的那一路，背景音被分掉'),

  /// 只放素材里的背景（水声、喷雾声、环境音；素材自带的口播被分掉）
  background('背景声', '素材的现场音，说话声被分掉'),

  /// 原封不动整条放（人声和背景都在，不分离）
  original('原声', '素材原样的整条声音，不分离');

  const MaterialAudioMode(this.label, this.hint);

  /// 界面和 CLI 共用同一份说法——两边措辞不一致，人对着文档找不到界面上那个词
  final String label;

  /// 一句补充，说清这一档到底放的是什么
  final String hint;

  /// 同一档用在**原片这一镜**上时的说明。四个档位是同一套，
  /// 但说的是两条不同的声音，文案不能共用一份
  String get sourceHint => switch (this) {
        MaterialAudioMode.none => '这一镜不放原片的声音',
        MaterialAudioMode.vocals => '原片这一段说话的那一路，现场音被分掉',
        MaterialAudioMode.background => '原片这一段的现场音，说话声被分掉',
        MaterialAudioMode.original => '原片这一段原样的整条声音，不分离',
      };

  /// 这一档要不要先跑分离（一条素材十几秒，见 [MaterialVocalCache]）
  bool get needsSeparation =>
      this == MaterialAudioMode.vocals || this == MaterialAudioMode.background;

  /// 这一档会不会出声
  bool get audible => this != MaterialAudioMode.none;

  static MaterialAudioMode? byName(String? name) {
    for (final m in MaterialAudioMode.values) {
      if (m.name == name) return m;
    }
    return null;
  }
}

/// 「替换分镜的声音」的设置：放哪一路 + 多大声。
class MaterialAudioSetting {
  final MaterialAudioMode mode;

  /// 压到原始音量的几成（0~1）
  final double volume;

  /// 默认压到四分之一——跟配乐同一个值。它叠在口播上，给大了会盖住台词，
  /// 而这条片子的主体是口播
  static const double defaultVolume = 0.25;

  /// 默认不播：升级一版不该让存量任务导出来的片子突然多出一层声音
  static const MaterialAudioSetting off =
      MaterialAudioSetting(mode: MaterialAudioMode.none);

  const MaterialAudioSetting({
    required this.mode,
    double volume = defaultVolume,
  }) : volume = volume < 0
            ? 0
            : volume > 1
                ? 1
                : volume;

  MaterialAudioSetting copyWith({MaterialAudioMode? mode, double? volume}) =>
      MaterialAudioSetting(
          mode: mode ?? this.mode, volume: volume ?? this.volume);

  Map<String, dynamic> toJson() => {'mode': mode.name, 'volume': volume};

  factory MaterialAudioSetting.fromJson(Map<String, dynamic>? json) {
    if (json == null) return off;
    final volume = (json['volume'] as num?)?.toDouble() ?? defaultVolume;
    final named = MaterialAudioMode.byName(json['mode'] as String?);
    if (named != null) return MaterialAudioSetting(mode: named, volume: volume);
    // 存量存档：这个设置原来只有「保留/不保留」两态，保留就是不分离的原声。
    // 认不出的档位名同样退回不播——不许拿一个猜的声音进成片
    return MaterialAudioSetting(
      mode: json['keep'] == true
          ? MaterialAudioMode.original
          : MaterialAudioMode.none,
      volume: volume,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MaterialAudioSetting &&
      other.mode == mode &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(mode, volume);
}

/// **新建任务**的「替换分镜的声音」默认档：原声。
///
/// 和 [MaterialAudioSetting.off] 的分工：那个是**存量任务**的缺省，
/// 不能动——升级一版不该让旧任务导出来的片子突然多一层声音
/// （用户 2026-09-10 定的：「默认改成原声，只对所有新任务有效……旧任务不管」）。
const MaterialAudioSetting newTaskMaterialAudio =
    MaterialAudioSetting(mode: MaterialAudioMode.original);

/// 任务级打底 + 镜头级覆盖 → 这一镜最终放哪一路声音。
///
/// 两级是产品定的：整条片子设一次省事，个别镜头（比如那条素材自己带口播）
/// 还能单独换一档或调小。**镜头的 `null` 是「跟随全片」**，
/// 而 [MaterialAudioMode.none] 是「这一镜明确别出声」——两者不是一回事。
MaterialAudioSetting resolveMaterialAudio({
  required MaterialAudioSetting taskDefault,
  MaterialAudioMode? shotMode,
  double? shotVolume,
}) =>
    MaterialAudioSetting(
      mode: shotMode ?? taskDefault.mode,
      volume: shotVolume ?? taskDefault.volume,
    );

/// 把一个变速倍率拆成 ffmpeg 的 `atempo` 滤镜链。
///
/// 为什么要拆：镜头替换是把候选变速填满原坑位（画面走 `setpts=PTS/factor`），
/// 声音必须同步变速，否则叠上去就是越走越偏。而 `atempo` 单节只保证
/// **0.5~2.0** 这一段（老版本 ffmpeg 超出就直接报错），2.9× 这种得连乘。
///
/// 几乎不变速时返回空——白插一道滤镜只会掉音质。
List<String> atempoChain(double factor) {
  if ((factor - 1).abs() < 1e-3) return const [];
  var remaining = factor;
  final chain = <String>[];
  while (remaining > 2.0) {
    chain.add('atempo=2.0');
    remaining /= 2.0;
  }
  while (remaining < 0.5) {
    chain.add('atempo=0.5');
    remaining /= 0.5;
  }
  chain.add('atempo=${_trimTail(remaining)}');
  return List.unmodifiable(chain);
}

/// 去掉浮点尾巴：`atempo=1.4499999999999999` 既难读也没意义
String _trimTail(double v) {
  final s = v.toStringAsFixed(6);
  return s.contains('.')
      ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : s;
}

/// 一个被替换的视觉镜头，它的素材声音该怎么叠回成片。
///
/// 由导出/预览那一层算好再交给音轨装配——那边才知道素材落到本地哪儿、
/// 变速多少、从第几秒起截（这三样都跟画面那一段用的是同一套参数，
/// 不然声音和画面对不上）。
class ShotMaterialAudio {
  /// 素材在本地的路径
  final String path;

  /// 画面变速了多少，声音要走同样的倍率
  final double speedFactor;

  /// 从素材的第几毫秒起截。null = 从头
  final int? trimStartMs;

  /// 压到原始音量的几成
  final double volume;

  /// 这一段在**成片**时间轴上的起点与长度
  final int composedStartMs;
  final int durationMs;

  /// 这是哪一镜（`U1·S2`），出事时要能指着说。
  ///
  /// 报「有一层声音过载了」等于没报——人得知道去调哪一层的音量
  final String label;

  const ShotMaterialAudio({
    required this.path,
    required this.speedFactor,
    required this.volume,
    required this.composedStartMs,
    required this.durationMs,
    this.label = '',
    this.trimStartMs,
  });
}

/// 这个单元被**整体替换**时放哪一路声音、多大声。
///
/// 默认「原声、满音量」——整体替换本来就是画面和声音一起换，
/// 那一段的口播来自素材。**和镜头级默认「不播放」正好相反**，
/// 而且必须相反：把这边也默认成不播放，存量任务导出来会整段没声音。
MaterialAudioSetting resolveWholeAudio(SemanticUnit unit) =>
    MaterialAudioSetting(
      mode: unit.wholeAudioMode ?? MaterialAudioMode.original,
      volume: unit.wholeAudioVolume ?? 1.0,
    );


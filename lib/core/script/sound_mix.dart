/// 三条声音轨的总控：**原声 / 配音 / 配乐**。
///
/// 用户的心智就是一张混音台——「三条轨可能同时播放，也可能调整其中一个，
/// 关闭也好，声音大小也好」。
///
/// 此前主预览下面只有一根滑杆，还名不副实：它叫「原声」、摆的位置像总音量，
/// 实际调的是「配音行没单独设时原声压到多少」。画面行没有口播、不参与那条
/// 规则，所以拉它**永远没反应**——用户只会以为软件坏了。
///
/// 这里把两件事分开：
///
/// - **总音量**（[source] / [voice] / [bgm]）：整条轨的大小，对所有行生效
/// - **闪避**（[duckSourceUnderVoice]）：有口播的段落把原声压到
///   [duckedSourceVolume]，因为原声会和口播叠成两份声音
///
/// 逐镜原声、逐段配乐是**相对值**，乘在总音量上——所以拉总音量，
/// 单独设过的段落也跟着变。
class SoundMix {
  /// 原声轨总音量（0~1）
  final double source;

  /// 配音轨总音量（0~1）
  final double voice;

  /// 配乐轨总音量（0~1）
  final double bgm;

  /// 静音钮。**和音量分开存**：静音是临时闭嘴，再点一下要回到原来的位置，
  /// 直接把音量写 0 就把滑杆位置弄丢了
  final bool sourceMuted;
  final bool voiceMuted;
  final bool bgmMuted;

  /// 有口播的段落自动压低原声。默认开——原声和口播叠在一起是两份声音
  final bool duckSourceUnderVoice;

  /// 压到多少（0 = 完全让位）。
  ///
  /// 这就是老档里 `sourceVolume` 字段的语义，原样搬过来：默认 0，
  /// 于是升级前后已有片子的声音一个字节不变
  final double duckedSourceVolume;

  const SoundMix({
    double source = 1.0,
    double voice = 1.0,
    double bgm = 1.0,
    this.sourceMuted = false,
    this.voiceMuted = false,
    this.bgmMuted = false,
    this.duckSourceUnderVoice = true,
    double duckedSourceVolume = 0.0,
  })  : source = source < 0 ? 0.0 : (source > 1 ? 1.0 : source),
        voice = voice < 0 ? 0.0 : (voice > 1 ? 1.0 : voice),
        bgm = bgm < 0 ? 0.0 : (bgm > 1 ? 1.0 : bgm),
        duckedSourceVolume = duckedSourceVolume < 0
            ? 0.0
            : (duckedSourceVolume > 1 ? 1.0 : duckedSourceVolume);

  /// 实际出多大：静音钮按下就是 0，但 [source] 本身不动
  double get effectiveSource => sourceMuted ? 0.0 : source;
  double get effectiveVoice => voiceMuted ? 0.0 : voice;
  double get effectiveBgm => bgmMuted ? 0.0 : bgm;

  SoundMix copyWith({
    double? source,
    double? voice,
    double? bgm,
    bool? sourceMuted,
    bool? voiceMuted,
    bool? bgmMuted,
    bool? duckSourceUnderVoice,
    double? duckedSourceVolume,
  }) =>
      SoundMix(
        source: source ?? this.source,
        voice: voice ?? this.voice,
        bgm: bgm ?? this.bgm,
        sourceMuted: sourceMuted ?? this.sourceMuted,
        voiceMuted: voiceMuted ?? this.voiceMuted,
        bgmMuted: bgmMuted ?? this.bgmMuted,
        duckSourceUnderVoice:
            duckSourceUnderVoice ?? this.duckSourceUnderVoice,
        duckedSourceVolume: duckedSourceVolume ?? this.duckedSourceVolume,
      );

  SoundMix withSourceMuted(bool muted) => copyWith(sourceMuted: muted);
  SoundMix withVoiceMuted(bool muted) => copyWith(voiceMuted: muted);
  SoundMix withBgmMuted(bool muted) => copyWith(bgmMuted: muted);

  /// 全默认时**写空对象**：老档打开不该凭空多出一堆字段，
  /// 那会让每个任务文件都在升级当天变脏
  Map<String, dynamic> toJson() => {
        if (source != 1.0) 'source': source,
        if (voice != 1.0) 'voice': voice,
        if (bgm != 1.0) 'bgm': bgm,
        if (sourceMuted) 'sourceMuted': true,
        if (voiceMuted) 'voiceMuted': true,
        if (bgmMuted) 'bgmMuted': true,
        if (!duckSourceUnderVoice) 'duck': false,
        if (duckedSourceVolume != 0.0) 'duckedSource': duckedSourceVolume,
      };

  /// 读不懂就用默认——一个坏字段不该让整条任务打不开
  static SoundMix fromJson(Object? raw) {
    if (raw is! Map) return const SoundMix();
    double num_(String key, double fallback) =>
        raw[key] is num ? (raw[key] as num).toDouble() : fallback;
    return SoundMix(
      source: num_('source', 1.0),
      voice: num_('voice', 1.0),
      bgm: num_('bgm', 1.0),
      sourceMuted: raw['sourceMuted'] == true,
      voiceMuted: raw['voiceMuted'] == true,
      bgmMuted: raw['bgmMuted'] == true,
      duckSourceUnderVoice: raw['duck'] != false,
      duckedSourceVolume: num_('duckedSource', 0.0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SoundMix &&
      other.source == source &&
      other.voice == voice &&
      other.bgm == bgm &&
      other.sourceMuted == sourceMuted &&
      other.voiceMuted == voiceMuted &&
      other.bgmMuted == bgmMuted &&
      other.duckSourceUnderVoice == duckSourceUnderVoice &&
      other.duckedSourceVolume == duckedSourceVolume;

  @override
  int get hashCode => Object.hash(source, voice, bgm, sourceMuted, voiceMuted,
      bgmMuted, duckSourceUnderVoice, duckedSourceVolume);
}

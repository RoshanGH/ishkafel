/// 脚本成片（编导台）的数据根：脚本行。
///
/// 「脚本即成片」——**行是唯一概念**（设计稿 2026-08-19）：
/// - **配音行**：有台词。配音生成后其时长是该行时间轴的根
/// - **画面行**：空文案但结构上存在——有画面、可铺 BGM；时长手填或随素材
///
/// 行类型不是用户选的，由文案有无**派生**：空行填上字自动变配音行，
/// 清空文案自动变画面行——编导只管写，不用理解「类型」这个概念。
library;

import '../audio/bgm_plan.dart';
import '../subtitle/subtitle_style.dart';

enum ScriptLineType { voiced, visual }

/// 一行配音的状态（派生，不落盘）：
/// - [none]：还没生成过
/// - [fresh]：配音与当前台词/音色/语速一致
/// - [stale]：台词（或音色/语速）改过了，配音是旧的——**旧配音仍可听**，
///   重新生成才花钱（设计稿：改字不自动重配，显式触发）
enum LineVoiceState { none, fresh, stale }

/// 配音里一个字的时间戳（字幕按它拆段）
class VoiceWord {
  final String text;
  final int startMs;
  final int endMs;

  const VoiceWord(
      {required this.text, required this.startMs, required this.endMs});

  Map<String, dynamic> toJson() =>
      {'text': text, 'startMs': startMs, 'endMs': endMs};

  static VoiceWord? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    final start = raw['startMs'];
    final end = raw['endMs'];
    if (text is! String || start is! int || end is! int) return null;
    return VoiceWord(text: text, startMs: start, endMs: end);
  }
}

/// 一行已生成的配音产物。
///
/// [sourceText]/[voiceId]/[speechRate] 是**生成时刻**的快照：跟行的当前值
/// 对不上就说明配音过期了（[ScriptLine.voiceState]）。按内容判定、
/// 不按「文件存在」判定——后者会静默放出上一个版本的声音。
class LineVoiceover {
  /// 音频文件（mp3），落在 `<dataDir>/voices/<taskId>/` 下，
  /// 删任务时随目录一并清走
  final String audioPath;

  /// 实际音频时长——这一行时间轴的根
  final int durationMs;

  final String sourceText;
  final String voiceId;
  final int speechRate;

  /// 字级时间戳（字幕用）
  final List<VoiceWord> words;

  LineVoiceover({
    required this.audioPath,
    required this.durationMs,
    required this.sourceText,
    required this.voiceId,
    required this.speechRate,
    List<VoiceWord> words = const [],
  }) : words = List.unmodifiable(words);

  Map<String, dynamic> toJson() => {
        'audioPath': audioPath,
        'durationMs': durationMs,
        'sourceText': sourceText,
        'voiceId': voiceId,
        'speechRate': speechRate,
        if (words.isNotEmpty) 'words': [for (final w in words) w.toJson()],
      };

  static LineVoiceover? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final audioPath = raw['audioPath'];
    final durationMs = raw['durationMs'];
    final sourceText = raw['sourceText'];
    final voiceId = raw['voiceId'];
    if (audioPath is! String ||
        durationMs is! int ||
        sourceText is! String ||
        voiceId is! String) {
      return null;
    }
    return LineVoiceover(
      audioPath: audioPath,
      durationMs: durationMs,
      sourceText: sourceText,
      voiceId: voiceId,
      speechRate: raw['speechRate'] is int ? raw['speechRate'] as int : 0,
      words: [
        if (raw['words'] is List)
          for (final w in raw['words'] as List) ?VoiceWord.tryFromJson(w),
      ],
    );
  }
}

/// 这一句在参考片里的区间（「参考视频」列的数据根）。
///
/// 上传成片提取脚本时，ASR 给出的每句时间戳直接落在行上；视频路径
/// 跟文档走（ScriptDoc.refVideoPath）——同一条参考片切出全部行。
class LineRef {
  final int startMs;
  final int endMs;

  /// 行级参考视频（手动给某一行上传的参考）；null = 用文档级
  /// ScriptDoc.refVideoPath（整片提取时的来源视频）
  final String? videoPath;

  /// 区间内的视觉切点（原片坐标，升序）：参考段按它切成多个「参考分镜」，
  /// 每镜一张卡、各自可播放/用它。提取脚本时由场景检测得出
  final List<int> cuts;

  /// 这一句在原片里的词级时间戳（**原片坐标**）。找镜头面板按参考
  /// 分镜（原子）检索时，用它裁出「这个原子时段说了哪几个字」当检索词
  final List<VoiceWord> words;

  LineRef({
    required this.startMs,
    required this.endMs,
    this.videoPath,
    List<int> cuts = const [],
    List<VoiceWord> words = const [],
  })  : cuts = List.unmodifiable(cuts),
        words = List.unmodifiable(words);

  int get durationMs => endMs - startMs;

  /// 第 [segIndex] 个参考分镜（原子）时段内说的话：词的时间中点归属。
  /// 没有词级数据（老档）或裁不出来时退回 [fallback]（整句）
  String segmentText(int segIndex, String fallback) {
    final segs = segments;
    if (segIndex < 0 || segIndex >= segs.length || words.isEmpty) {
      return fallback;
    }
    final (s0, e0) = segs[segIndex];
    final text = [
      for (final w in words)
        if ((w.startMs + w.endMs) / 2 >= s0 && (w.startMs + w.endMs) / 2 < e0)
          w.text,
    ].join();
    return text.isEmpty ? fallback : text;
  }

  /// 参考分镜的区间序列（按切点拆；没有切点就是整段一镜）。
  /// 短于 400ms 的碎段并回前一段——闪一下的卡没有参考价值
  List<(int, int)> get segments {
    final points = [
      startMs,
      ...cuts.where((c) => c > startMs && c < endMs),
      endMs,
    ];
    final out = <(int, int)>[];
    for (var i = 0; i < points.length - 1; i++) {
      final s0 = points[i];
      final e0 = points[i + 1];
      if (e0 - s0 < 400 && out.isNotEmpty) {
        final last = out.removeLast();
        out.add((last.$1, e0));
      } else {
        out.add((s0, e0));
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        if (videoPath != null) 'videoPath': videoPath,
        if (cuts.isNotEmpty) 'cuts': cuts,
        if (words.isNotEmpty) 'words': [for (final w in words) w.toJson()],
      };

  static LineRef? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = raw['startMs'];
    final end = raw['endMs'];
    if (start is! int || end is! int || end <= start) return null;
    return LineRef(
      startMs: start,
      endMs: end,
      videoPath: raw['videoPath'] is String ? raw['videoPath'] as String : null,
      cuts: [
        if (raw['cuts'] is List)
          for (final c in raw['cuts'] as List)
            if (c is int) c,
      ],
      words: [
        if (raw['words'] is List)
          for (final w in raw['words'] as List) ?VoiceWord.tryFromJson(w),
      ],
    );
  }
}

/// 一行里的一个镜头位：从 miaoa 挑中的一条分镜素材。
///
/// 存的是素材的**身份与元信息快照**（名字/台词/画面描述/缩略图），不存
/// 签名地址的时效性内容——previewUrl 会过期，播放时按 id 重新解析或用
/// 已下载的本地文件。时长来自候选面板的规格探测；探不出为 null（不用 0 冒充）。
class LineShot {
  final int materialId;
  final String name;
  final String voiceover;
  final String sceneDescription;
  final String? thumbnailUrl;
  final String? fileKey;
  final int? durationMs;

  /// 从素材的哪一刻开始截（框选起点，素材内坐标毫秒）
  final int trimStartMs;

  /// 显式变速（1.0 = 原速）。变速改的是「可用量」：素材 6s 在 1.5x 下
  /// 只够出 4s 画面（见 availableMs）
  final double speed;

  /// 分到的**成片播放时长**（毫秒）。null = 还没分配。
  /// 行内所有镜头的 allocMs 之和 = 行时长（总长锁死）
  final int? allocMs;

  /// 本地视频源（非 miaoa 素材）：参考片「用它」一键作镜头时走这里。
  /// 非空时 materialId 只是行内唯一的负数占位，不参与下载/防撞车
  final String? localSource;

  /// 这一镜的字幕文本（**字幕写在镜头上**——用户定的模型）。
  /// null = 跟随自动匹配（按配音词时间戳算这镜时段说出口的字，
  /// 时长一改就重算）；非空 = **手改**，从此不跟自动走，直到被清空。
  /// 多镜共用一句 = 几个镜头写同一句
  final String? subtitleText;

  const LineShot({
    required this.materialId,
    required this.name,
    this.voiceover = '',
    this.sceneDescription = '',
    this.thumbnailUrl,
    this.fileKey,
    this.durationMs,
    this.trimStartMs = 0,
    this.speed = 1.0,
    this.allocMs,
    this.localSource,
    this.subtitleText,
  });

  /// 从 [trimStartMs] 起、按 [speed] 播，这条素材最多还能出多少**成片时长**。
  /// 素材时长未知时给一个「足够大」——探测失败不该把镜头卡死。
  /// 本地源（参考段）的 trimStartMs 是**原片坐标**、durationMs 是区间长，
  /// 可用量就是整个区间
  int get availableMs {
    if (durationMs == null) return 1 << 30;
    if (localSource != null) {
      return (durationMs! / speed).floor().clamp(0, 1 << 30);
    }
    return ((durationMs! - trimStartMs) / speed).floor().clamp(0, 1 << 30);
  }

  /// 这一镜按当前分配要消耗素材多长（素材内坐标）
  int get consumedSourceMs => ((allocMs ?? 0) * speed).round();

  LineShot copyWith({
    int? trimStartMs,
    double? speed,
    Object? allocMs = _unsetAlloc,
    Object? subtitleText = _unsetAlloc,
  }) =>
      LineShot(
        materialId: materialId,
        name: name,
        voiceover: voiceover,
        sceneDescription: sceneDescription,
        thumbnailUrl: thumbnailUrl,
        fileKey: fileKey,
        durationMs: durationMs,
        trimStartMs: trimStartMs ?? this.trimStartMs,
        speed: speed ?? this.speed,
        allocMs: allocMs == _unsetAlloc ? this.allocMs : allocMs as int?,
        localSource: localSource,
        subtitleText: subtitleText == _unsetAlloc
            ? this.subtitleText
            : subtitleText as String?,
      );

  static const _unsetAlloc = Object();

  /// 卡片上显示什么：台词 → 画面描述 → 素材名
  String get label => voiceover.isNotEmpty
      ? voiceover
      : (sceneDescription.isNotEmpty ? sceneDescription : name);

  Map<String, dynamic> toJson() => {
        'materialId': materialId,
        'name': name,
        if (voiceover.isNotEmpty) 'voiceover': voiceover,
        if (sceneDescription.isNotEmpty) 'sceneDescription': sceneDescription,
        if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
        if (fileKey != null) 'fileKey': fileKey,
        if (durationMs != null) 'durationMs': durationMs,
        if (trimStartMs != 0) 'trimStartMs': trimStartMs,
        if (speed != 1.0) 'speed': speed,
        if (allocMs != null) 'allocMs': allocMs,
        if (localSource != null) 'localSource': localSource,
        if (subtitleText != null) 'subtitleText': subtitleText,
      };

  static LineShot? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['materialId'];
    if (id is! int) return null;
    return LineShot(
      materialId: id,
      name: raw['name'] is String ? raw['name'] as String : '未命名素材',
      voiceover: raw['voiceover'] is String ? raw['voiceover'] as String : '',
      sceneDescription: raw['sceneDescription'] is String
          ? raw['sceneDescription'] as String
          : '',
      thumbnailUrl:
          raw['thumbnailUrl'] is String ? raw['thumbnailUrl'] as String : null,
      fileKey: raw['fileKey'] is String ? raw['fileKey'] as String : null,
      durationMs: raw['durationMs'] is int ? raw['durationMs'] as int : null,
      trimStartMs:
          raw['trimStartMs'] is int ? raw['trimStartMs'] as int : 0,
      speed: raw['speed'] is num ? (raw['speed'] as num).toDouble() : 1.0,
      allocMs: raw['allocMs'] is int ? raw['allocMs'] as int : null,
      localSource:
          raw['localSource'] is String ? raw['localSource'] as String : null,
      subtitleText:
          raw['subtitleText'] is String ? raw['subtitleText'] as String : null,
    );
  }
}

class ScriptLine {
  /// 稳定身份：重排、镜头组引用、配音产物归属都靠它——行的内容会变，
  /// 身份不变
  final String id;

  final String text;

  /// 画面行的手填时长（毫秒）。null = 未填（随所选素材）。
  /// 配音行忽略此字段——配音时长才是根
  final int? manualMs;

  /// 行标签（M3 打标后挂上，可改可删；检索时自动预填）
  final List<String> tags;

  /// 这一行选定的音色 id（VoiceCatalog）。null = 还没选
  final String? voiceId;

  /// 语速（火山口径：0 = 原速，100 = 2 倍速，-50 = 0.5 倍速）
  final int speechRate;

  /// 已生成的配音产物；null = 还没生成过
  final LineVoiceover? voiceover;

  /// 这一行的镜头序列（挑中的 miaoa 分镜，按播放顺序排）
  final List<LineShot> shots;

  /// 这一句在参考片里的区间（提取脚本时自动落；手写的行没有）
  final LineRef? reference;

  /// 行级字幕样式覆盖；null = 跟随全局（素材自带字幕位置不同时按行改）
  final SubtitleStyle? subtitleOverride;

  /// 台词语义单元内的**小行切分**：把台词文本与镜头序列同步分组——
  /// 「家人们」指定给前两个镜头、后半句归其余镜头。每个切点是
  /// (文本字符索引, 镜头下标)，两轴都升序；空 = 不分组（整句一组）。
  /// 字幕的显示区间跟组走：这段字横跨组内所有镜头
  final List<(int, int)> sublineCuts;

  ScriptLine({
    required this.id,
    required this.text,
    this.manualMs,
    List<String> tags = const [],
    this.voiceId,
    this.speechRate = 0,
    this.voiceover,
    List<LineShot> shots = const [],
    this.reference,
    this.subtitleOverride,
    List<(int, int)> sublineCuts = const [],
  })  : tags = List.unmodifiable(tags),
        shots = List.unmodifiable(shots),
        sublineCuts = List.unmodifiable(sublineCuts);

  static int _seq = 0;

  /// 新行。id 用时间戳+序号，进程内唯一且落盘后稳定
  factory ScriptLine.create({String text = '', LineRef? reference}) =>
      ScriptLine(
        id: 'l${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
            '${(_seq++).toRadixString(36)}',
        text: text,
        reference: reference,
      );

  /// 有字就是配音行，没字就是画面行——由内容派生，不由用户选择
  ScriptLineType get type =>
      text.trim().isEmpty ? ScriptLineType.visual : ScriptLineType.voiced;

  /// 配音状态（派生）：产物快照与当前台词/音色/语速逐项对比
  LineVoiceState get voiceState {
    final vo = voiceover;
    if (vo == null) return LineVoiceState.none;
    final current = text.trim();
    final fresh = vo.sourceText == current &&
        vo.voiceId == (voiceId ?? vo.voiceId) &&
        vo.speechRate == speechRate;
    return fresh ? LineVoiceState.fresh : LineVoiceState.stale;
  }

  ScriptLine _copy({
    String? text,
    Object? manualMs = _unset,
    List<String>? tags,
    Object? voiceId = _unset,
    int? speechRate,
    Object? voiceover = _unset,
    List<LineShot>? shots,
    Object? subtitleOverride = _unset,
    List<(int, int)>? sublineCuts,
  }) =>
      ScriptLine(
        id: id,
        text: text ?? this.text,
        manualMs: manualMs == _unset ? this.manualMs : manualMs as int?,
        tags: tags ?? this.tags,
        voiceId: voiceId == _unset ? this.voiceId : voiceId as String?,
        speechRate: speechRate ?? this.speechRate,
        voiceover:
            voiceover == _unset ? this.voiceover : voiceover as LineVoiceover?,
        shots: shots ?? this.shots,
        reference: reference,
        subtitleOverride: subtitleOverride == _unset
            ? this.subtitleOverride
            : subtitleOverride as SubtitleStyle?,
        sublineCuts: sublineCuts ?? this.sublineCuts,
      );

  static const _unset = Object();

  ScriptLine withText(String next) => _copy(text: next);

  ScriptLine withManualMs(int? ms) => _copy(manualMs: ms);

  ScriptLine withTags(List<String> next) => _copy(tags: next);

  ScriptLine withVoiceId(String? id) => _copy(voiceId: id);

  ScriptLine withSpeechRate(int rate) => _copy(speechRate: rate);

  /// 挂上新生成的配音。**不清旧文件**——旧音频的删除由调用方负责
  /// （生成成功后才删旧的，失败时旧配音还能听）
  ScriptLine withVoiceover(LineVoiceover? vo) => _copy(voiceover: vo);

  ScriptLine withShots(List<LineShot> next) => _copy(shots: next);

  ScriptLine withSubtitleOverride(SubtitleStyle? next) =>
      _copy(subtitleOverride: next);

  ScriptLine withSublineCuts(List<(int, int)> next) =>
      _copy(sublineCuts: next);

  /// 镜头级字幕段（行时间轴）：**字幕写在镜头上**。
  ///
  /// 每镜的文本 = 人写的 [LineShot.subtitleText]（空串 = 不要字幕），
  /// 没写则自动预填「这镜时段内说出口的字」（配音词时间戳，词的时间
  /// 中点归属）。相邻镜头文本相同合并为一条连续段——多镜共用一句时
  /// 字幕不闪断。预览与导出都用这一份
  List<({int startMs, int endMs, String text})> get shotSubtitleSegments {
    final vo = voiceover;
    final out = <({int startMs, int endMs, String text})>[];
    var cursor = 0;
    for (final shot in shots) {
      final alloc = shot.allocMs ?? 0;
      if (alloc <= 0) continue;
      final start = cursor;
      final end = cursor + alloc;
      cursor = end;
      String segText;
      if (shot.subtitleText != null) {
        segText = shot.subtitleText!.trim();
      } else if (vo != null && vo.words.isNotEmpty) {
        segText = [
          for (final w in vo.words)
            if ((w.startMs + w.endMs) / 2 >= start &&
                (w.startMs + w.endMs) / 2 < end)
              w.text,
        ].join();
      } else {
        // 老配音没有词级时间戳：整句兜底
        segText = text.trim();
      }
      if (segText.isEmpty) continue;
      if (out.isNotEmpty &&
          out.last.text == segText &&
          out.last.endMs == start) {
        final last = out.removeLast();
        out.add((startMs: last.startMs, endMs: end, text: segText));
      } else {
        out.add((startMs: start, endMs: end, text: segText));
      }
    }
    return out;
  }

  /// 有效切点：文本与镜头两轴都在界内且严格递增——镜头删了、台词改了
  /// 之后越界的切点自动失效（宽容派生，不炸也不静默保留错数据）
  List<(int, int)> get _validCuts {
    final out = <(int, int)>[];
    var lastChar = 0;
    var lastShot = 0;
    for (final (c, s) in sublineCuts) {
      if (c <= lastChar || c >= text.length) continue;
      if (s <= lastShot || s >= shots.length) continue;
      out.add((c, s));
      lastChar = c;
      lastShot = s;
    }
    return out;
  }

  /// 小行序列：每个小行 = 一段台词文本 + 它对应的镜头范围
  /// [shotStart, shotEnd)。没有切点（或切点全失效）= 整句一组
  List<({String text, int shotStart, int shotEnd})> get sublines {
    final cuts = _validCuts;
    final out = <({String text, int shotStart, int shotEnd})>[];
    var charFrom = 0;
    var shotFrom = 0;
    for (final (c, s) in [...cuts, (text.length, shots.length)]) {
      out.add((
        text: text.substring(charFrom, c),
        shotStart: shotFrom,
        shotEnd: s,
      ));
      charFrom = c;
      shotFrom = s;
    }
    return out;
  }

  /// 各小行的时间区间（行时间轴）：组内镜头 allocMs 累计。
  /// 字幕的显示区间用它——这段字横跨组内所有镜头
  List<({int startMs, int endMs, String text})> get sublineSpans {
    final out = <({int startMs, int endMs, String text})>[];
    var cursor = 0;
    for (final sub in sublines) {
      var span = 0;
      for (var i = sub.shotStart; i < sub.shotEnd && i < shots.length; i++) {
        span += shots[i].allocMs ?? 0;
      }
      out.add((startMs: cursor, endMs: cursor + span, text: sub.text));
      cursor += span;
    }
    return out;
  }

  /// 换参考段（行级上传参考视频用）。_copy 不动 reference（它跟行身份走），
  /// 这里显式重建
  ScriptLine withReference(LineRef? next) => ScriptLine(
        id: id,
        text: text,
        manualMs: manualMs,
        tags: tags,
        voiceId: voiceId,
        speechRate: speechRate,
        voiceover: voiceover,
        shots: shots,
        reference: next,
        subtitleOverride: subtitleOverride,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (manualMs != null) 'manualMs': manualMs,
        if (tags.isNotEmpty) 'tags': tags,
        if (voiceId != null) 'voiceId': voiceId,
        if (speechRate != 0) 'speechRate': speechRate,
        if (voiceover != null) 'voiceover': voiceover!.toJson(),
        if (shots.isNotEmpty) 'shots': [for (final s in shots) s.toJson()],
        if (reference != null) 'reference': reference!.toJson(),
        if (subtitleOverride != null)
          'subtitleOverride': subtitleOverride!.toJson(),
        if (sublineCuts.isNotEmpty)
          'sublineCuts': [
            for (final (c, sh) in sublineCuts) {'char': c, 'shot': sh},
          ],
      };

  /// 宽松解析：一条坏行只丢它自己，不牵连整份脚本
  static ScriptLine? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || id.isEmpty || text is! String) return null;
    return ScriptLine(
      id: id,
      text: text,
      manualMs: raw['manualMs'] is int ? raw['manualMs'] as int : null,
      tags: [
        if (raw['tags'] is List)
          for (final t in raw['tags'] as List)
            if (t is String) t,
      ],
      voiceId: raw['voiceId'] is String ? raw['voiceId'] as String : null,
      speechRate: raw['speechRate'] is int ? raw['speechRate'] as int : 0,
      voiceover: LineVoiceover.tryFromJson(raw['voiceover']),
      shots: [
        if (raw['shots'] is List)
          for (final s in raw['shots'] as List) ?LineShot.tryFromJson(s),
      ],
      reference: LineRef.tryFromJson(raw['reference']),
      subtitleOverride: raw['subtitleOverride'] is Map
          ? SubtitleStyle.fromJson(raw['subtitleOverride'])
          : null,
      sublineCuts: [
        if (raw['sublineCuts'] is List)
          for (final c in raw['sublineCuts'] as List)
            if (c is Map && c['char'] is int && c['shot'] is int)
              (c['char'] as int, c['shot'] as int),
      ],
    );
  }
}

/// 一段配乐铺在哪几行上（行区间，闭区间）。
///
/// 相邻两段同一首曲子时播放连续不重头（BgmSegment 引擎的同一语义，
/// 预览构轨时合并区间实现）。
class ScriptBgmSegment {
  final int startLine;
  final int endLine;
  final BgmMaterial material;
  final double volume;

  const ScriptBgmSegment({
    required this.startLine,
    required this.endLine,
    required this.material,
    required this.volume,
  });

  Map<String, dynamic> toJson() => {
        'startLine': startLine,
        'endLine': endLine,
        'material': material.toJson(),
        'volume': volume,
      };

  static ScriptBgmSegment? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = raw['startLine'];
    final end = raw['endLine'];
    final material = BgmMaterial.tryFromJson(raw['material']);
    if (start is! int || end is! int || end < start || material == null) {
      return null;
    }
    return ScriptBgmSegment(
      startLine: start,
      endLine: end,
      material: material,
      volume: raw['volume'] is num
          ? (raw['volume'] as num).toDouble().clamp(0.0, 1.0)
          : BgmSegment.defaultVolume,
    );
  }
}

/// 一份脚本。全部操作不可变——返回新文档，绝不原地改。
class ScriptDoc {
  final List<ScriptLine> lines;

  /// 全局字幕样式（位置/字号/颜色/形态）。行级覆盖后续版本挂到行上
  final SubtitleStyle subtitle;

  /// 配乐段（行区间铺设，可多段多曲）。空 = 不配乐。
  /// 旧档的整片单曲（bgm/bgmVolume 字段）读取时迁移成一段全区间
  final List<ScriptBgmSegment> bgmSegments;

  /// 提取脚本的来源视频（行的 reference 区间都指向它）；手写脚本为 null
  final String? refVideoPath;

  ScriptDoc(
    List<ScriptLine> lines, {
    this.subtitle = SubtitleStyle.standard,
    List<ScriptBgmSegment> bgmSegments = const [],
    this.refVideoPath,
  })  : lines = List.unmodifiable(lines),
        bgmSegments = List.unmodifiable(bgmSegments);

  /// 新脚本自带一个空行：编导打开就能写，不用先学会「加行」
  factory ScriptDoc.empty() => ScriptDoc([ScriptLine.create()]);

  /// 换行列表、保留全局设置（字幕/配乐/参考片跟文档走，不跟行操作走）
  ScriptDoc _withLines(List<ScriptLine> next) => ScriptDoc(next,
      subtitle: subtitle,
      bgmSegments: bgmSegments,
      refVideoPath: refVideoPath);

  ScriptDoc withSubtitle(SubtitleStyle next) => ScriptDoc(lines,
      subtitle: next,
      bgmSegments: bgmSegments,
      refVideoPath: refVideoPath);

  ScriptDoc withBgmSegments(List<ScriptBgmSegment> next) => ScriptDoc(lines,
      subtitle: subtitle, bgmSegments: next, refVideoPath: refVideoPath);

  ScriptDoc insertAfter(int index, {String text = ''}) {
    final next = [...lines];
    next.insert(index + 1, ScriptLine.create(text: text));
    return _withLines(next);
  }

  /// 最后一行不许删——脚本至少有一行可写
  ScriptDoc removeAt(int index) {
    if (lines.length <= 1 || index < 0 || index >= lines.length) return this;
    return _withLines([...lines]..removeAt(index));
  }

  ScriptDoc move(int from, int to) {
    if (from < 0 || from >= lines.length || to < 0 || to >= lines.length) {
      return this;
    }
    final next = [...lines];
    final line = next.removeAt(from);
    next.insert(to, line);
    return _withLines(next);
  }

  ScriptDoc updateText(int index, String text) =>
      _update(index, (line) => line.withText(text));

  ScriptDoc setManualMs(int index, int? ms) =>
      _update(index, (line) => line.withManualMs(ms));

  ScriptDoc setTags(int index, List<String> tags) =>
      _update(index, (line) => line.withTags(tags));

  ScriptDoc setVoiceId(int index, String? voiceId) =>
      _update(index, (line) => line.withVoiceId(voiceId));

  ScriptDoc setSpeechRate(int index, int rate) =>
      _update(index, (line) => line.withSpeechRate(rate));

  /// 按行 id 挂配音（生成是异步的，期间行可能被移动，下标不可靠）
  ScriptDoc setVoiceoverById(String lineId, LineVoiceover vo) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withVoiceover(vo));
  }

  /// 按行 id 换镜头序列（找镜头面板是异步弹层，同理不信下标）
  ScriptDoc setShotsById(String lineId, List<LineShot> shots) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withShots(shots));
  }

  /// 按行 id 换标签
  ScriptDoc setTagsById(String lineId, List<String> tags) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withTags(tags));
  }

  /// 按行 id 给某一镜写字幕（null = 恢复自动跟随词时间戳）
  ScriptDoc setShotSubtitleById(String lineId, int shotIndex, String? text) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) {
      if (shotIndex < 0 || shotIndex >= line.shots.length) return line;
      final shots = [...line.shots];
      shots[shotIndex] = shots[shotIndex].copyWith(subtitleText: text);
      return line.withShots(shots);
    });
  }

  /// 按行 id 设小行切分（台词段 ↔ 镜头组的指定）
  ScriptDoc setSublineCutsById(String lineId, List<(int, int)> cuts) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withSublineCuts(cuts));
  }

  /// 按行 id 换参考段（行级参考视频上传）
  ScriptDoc setReferenceById(String lineId, LineRef? reference) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withReference(reference));
  }

  /// 按行 id 设字幕覆盖（null = 恢复跟随全局）
  ScriptDoc setSubtitleOverrideById(String lineId, SubtitleStyle? style) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withSubtitleOverride(style));
  }

  ScriptDoc _update(int index, ScriptLine Function(ScriptLine) f) {
    if (index < 0 || index >= lines.length) return this;
    final next = [...lines];
    next[index] = f(next[index]);
    return _withLines(next);
  }

  Map<String, dynamic> toJson() => {
        'lines': [for (final l in lines) l.toJson()],
        'subtitle': subtitle.toJson(),
        if (bgmSegments.isNotEmpty)
          'bgmSegments': [for (final s in bgmSegments) s.toJson()],
        if (refVideoPath != null) 'refVideoPath': refVideoPath,
      };

  /// 宽松解析；整体坏掉退回空脚本（打不开任务比丢一份草稿更糟）
  static ScriptDoc fromJson(Object? raw) {
    if (raw is! Map) return ScriptDoc.empty();
    final rawLines = raw['lines'];
    if (rawLines is! List) return ScriptDoc.empty();
    final lines = [
      for (final l in rawLines) ?ScriptLine.tryFromJson(l),
    ];
    if (lines.isEmpty) return ScriptDoc.empty();
    // 旧档迁移：整片单曲（bgm/bgmVolume）→ 一段全区间
    final legacy = BgmMaterial.tryFromJson(raw['bgm']);
    final segments = [
      if (raw['bgmSegments'] is List)
        for (final s in raw['bgmSegments'] as List)
          ?ScriptBgmSegment.tryFromJson(s),
    ];
    return ScriptDoc(
      lines,
      subtitle: SubtitleStyle.fromJson(raw['subtitle']),
      bgmSegments: segments.isNotEmpty
          ? segments
          : [
              if (legacy != null)
                ScriptBgmSegment(
                  startLine: 0,
                  endLine: lines.length - 1,
                  material: legacy,
                  volume: raw['bgmVolume'] is num
                      ? (raw['bgmVolume'] as num).toDouble().clamp(0.0, 1.0)
                      : BgmSegment.defaultVolume,
                ),
            ],
      refVideoPath: raw['refVideoPath'] is String
          ? raw['refVideoPath'] as String
          : null,
    );
  }
}

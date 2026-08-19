/// 脚本成片（编导台）的数据根：脚本行。
///
/// 「脚本即成片」——**行是唯一概念**（设计稿 2026-08-19）：
/// - **配音行**：有台词。配音生成后其时长是该行时间轴的根
/// - **画面行**：空文案但结构上存在——有画面、可铺 BGM；时长手填或随素材
///
/// 行类型不是用户选的，由文案有无**派生**：空行填上字自动变配音行，
/// 清空文案自动变画面行——编导只管写，不用理解「类型」这个概念。
library;

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

  ScriptLine({
    required this.id,
    required this.text,
    this.manualMs,
    List<String> tags = const [],
    this.voiceId,
    this.speechRate = 0,
    this.voiceover,
  }) : tags = List.unmodifiable(tags);

  static int _seq = 0;

  /// 新行。id 用时间戳+序号，进程内唯一且落盘后稳定
  factory ScriptLine.create({String text = ''}) => ScriptLine(
        id: 'l${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
            '${(_seq++).toRadixString(36)}',
        text: text,
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (manualMs != null) 'manualMs': manualMs,
        if (tags.isNotEmpty) 'tags': tags,
        if (voiceId != null) 'voiceId': voiceId,
        if (speechRate != 0) 'speechRate': speechRate,
        if (voiceover != null) 'voiceover': voiceover!.toJson(),
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
    );
  }
}

/// 一份脚本。全部操作不可变——返回新文档，绝不原地改。
class ScriptDoc {
  final List<ScriptLine> lines;

  ScriptDoc(List<ScriptLine> lines) : lines = List.unmodifiable(lines);

  /// 新脚本自带一个空行：编导打开就能写，不用先学会「加行」
  factory ScriptDoc.empty() => ScriptDoc([ScriptLine.create()]);

  ScriptDoc insertAfter(int index, {String text = ''}) {
    final next = [...lines];
    next.insert(index + 1, ScriptLine.create(text: text));
    return ScriptDoc(next);
  }

  /// 最后一行不许删——脚本至少有一行可写
  ScriptDoc removeAt(int index) {
    if (lines.length <= 1 || index < 0 || index >= lines.length) return this;
    return ScriptDoc([...lines]..removeAt(index));
  }

  ScriptDoc move(int from, int to) {
    if (from < 0 || from >= lines.length || to < 0 || to >= lines.length) {
      return this;
    }
    final next = [...lines];
    final line = next.removeAt(from);
    next.insert(to, line);
    return ScriptDoc(next);
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

  ScriptDoc _update(int index, ScriptLine Function(ScriptLine) f) {
    if (index < 0 || index >= lines.length) return this;
    final next = [...lines];
    next[index] = f(next[index]);
    return ScriptDoc(next);
  }

  Map<String, dynamic> toJson() =>
      {'lines': [for (final l in lines) l.toJson()]};

  /// 宽松解析；整体坏掉退回空脚本（打不开任务比丢一份草稿更糟）
  static ScriptDoc fromJson(Object? raw) {
    if (raw is! Map) return ScriptDoc.empty();
    final rawLines = raw['lines'];
    if (rawLines is! List) return ScriptDoc.empty();
    final lines = [
      for (final l in rawLines) ?ScriptLine.tryFromJson(l),
    ];
    return lines.isEmpty ? ScriptDoc.empty() : ScriptDoc(lines);
  }
}

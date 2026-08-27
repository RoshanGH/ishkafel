/// 脚本成片（编导台）的数据根：脚本行。
///
/// 「脚本即成片」——**行是唯一概念**（设计稿 2026-08-19）：
/// - **配音行**：有台词。配音生成后其时长是该行时间轴的根
/// - **画面行**：空文案但结构上存在——有画面、可铺 BGM；时长手填或随素材
///
/// 行类型不是用户选的，由文案有无**派生**：空行填上字自动变配音行，
/// 清空文案自动变画面行——编导只管写，不用理解「类型」这个概念。
library;

import 'sound_mix.dart';
import '../audio/bgm_plan.dart';
import '../analysis/providers.dart' show AsrSentence, AsrWord;
import '../subtitle/subtitle_overlay.dart';
import '../subtitle/subtitle_style.dart';
import 'voice_qc.dart';

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

/// 一个**参考视觉镜头**的理解结果（按需打标后缓存在行上）。
///
/// 视觉镜头层的检索键是**视觉的**：标签、画面描述、首帧图——不是台词
/// （台词是台词语义单元层的键）。[startMs] 是这一镜在原片里的起点，
/// 切点变了就对不上、自动失效，不会拿旧结论去搜新画面。
class RefShotMeta {
  final int startMs;
  final String description;
  final List<String> tags;

  /// 这一镜的首帧图（本地路径）——「找相似」的查询帧
  final String? framePath;

  RefShotMeta({
    required this.startMs,
    this.description = '',
    List<String> tags = const [],
    this.framePath,
  }) : tags = List.unmodifiable(tags);

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        if (description.isNotEmpty) 'description': description,
        if (tags.isNotEmpty) 'tags': tags,
        if (framePath != null) 'framePath': framePath,
      };

  static RefShotMeta? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = raw['startMs'];
    if (start is! int) return null;
    return RefShotMeta(
      startMs: start,
      description:
          raw['description'] is String ? raw['description'] as String : '',
      tags: [
        if (raw['tags'] is List)
          for (final t in raw['tags'] as List)
            if (t is String) t,
      ],
      framePath:
          raw['framePath'] is String ? raw['framePath'] as String : null,
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

  /// 这一句在原片里的词级时间戳（**原片坐标**）。
  /// **只用于展示**「参考这一段说了什么」——不回填脚本、不参与检索
  /// （单元层的检索台词永远是脚本里的那句）
  final List<VoiceWord> words;

  /// 参考图（手动传的一张图；与 [videoPath] 二选一）。
  /// 图没有时长与台词，它天然就是「首帧」，只给视觉镜头层当查询帧
  final String? imagePath;

  /// 各参考视觉镜头的打标结果（按需打、缓存复用）
  final List<RefShotMeta> shotMeta;

  LineRef({
    required this.startMs,
    required this.endMs,
    this.videoPath,
    this.imagePath,
    List<int> cuts = const [],
    List<VoiceWord> words = const [],
    List<RefShotMeta> shotMeta = const [],
  })  : cuts = List.unmodifiable(cuts),
        words = List.unmodifiable(words),
        shotMeta = List.unmodifiable(shotMeta);

  /// 起点为 [startMs] 的那一镜的打标结果；没打过或切点变了返回 null
  RefShotMeta? metaAt(int startMs) {
    for (final m in shotMeta) {
      if (m.startMs == startMs) return m;
    }
    return null;
  }

  /// 换掉（或新增）某一镜的打标结果——不可变，返回新 LineRef
  LineRef withShotMeta(RefShotMeta meta) => LineRef(
        startMs: startMs,
        endMs: endMs,
        videoPath: videoPath,
        imagePath: imagePath,
        cuts: cuts,
        words: words,
        shotMeta: [
          for (final m in shotMeta)
            if (m.startMs != meta.startMs) m,
          meta,
        ]..sort((a, b) => a.startMs.compareTo(b.startMs)),
      );

  /// 换切点（就地重新做视觉切分后）——切点一变，旧的镜头打标全部作废
  LineRef withCuts(List<int> next) => LineRef(
        startMs: startMs,
        endMs: endMs,
        videoPath: videoPath,
        imagePath: imagePath,
        cuts: next,
        words: words,
      );

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
        if (imagePath != null) 'imagePath': imagePath,
        if (cuts.isNotEmpty) 'cuts': cuts,
        if (words.isNotEmpty) 'words': [for (final w in words) w.toJson()],
        if (shotMeta.isNotEmpty)
          'shotMeta': [for (final m in shotMeta) m.toJson()],
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
      imagePath:
          raw['imagePath'] is String ? raw['imagePath'] as String : null,
      words: [
        if (raw['words'] is List)
          for (final w in raw['words'] as List) ?VoiceWord.tryFromJson(w),
      ],
      shotMeta: [
        if (raw['shotMeta'] is List)
          for (final m in raw['shotMeta'] as List) ?RefShotMeta.tryFromJson(m),
      ],
    );
  }
}

/// 一屏字幕（**屏是一等公民**：字幕的节奏跟语言走，画面的节奏跟镜头走，
/// 两条独立的轨）。
///
/// [startWord] 是这一屏从行内第几个词开始——**只记切点，不记时间**，
/// 所以镜头时长怎么改，屏都自愈；[text] 只在人真的改了字时才存
/// （null = 用这几个词拼出来的原文，'' = 这一屏不出字）。
class SubtitleScreen {
  final int startWord;
  final String? text;

  const SubtitleScreen({required this.startWord, this.text});

  SubtitleScreen copyWith({int? startWord, Object? text = _unsetText}) =>
      SubtitleScreen(
        startWord: startWord ?? this.startWord,
        text: identical(text, _unsetText) ? this.text : text as String?,
      );

  static const _unsetText = Object();

  Map<String, dynamic> toJson() =>
      {'startWord': startWord, if (text != null) 'text': text};

  static SubtitleScreen? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final w = raw['startWord'];
    if (w is! int || w < 0) return null;
    return SubtitleScreen(
      startWord: w,
      text: raw['text'] is String ? raw['text'] as String : null,
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

  /// 这一镜的**素材原声**音量（0~1）。null = 跟随全片设置。
  ///
  /// 分镜素材自带的声音里常有音效（喷雾声、开门声），全丢掉片子会发干；
  /// 但有的素材背景嘈杂，又得单独压下去。所以全局定基调、这里开小灶
  final double? sourceVolume;

  /// 这一镜绑住台词的哪几个字（词序号区间 `[startWord, endWord)`）。
  ///
  /// **划词建镜**：人在台词上选中「如果你觉得有点贵」，这一镜的时长就是
  /// 这几个字的朗读时长——不用自己听、自己数秒数再填进来。
  ///
  /// 为什么记词序号而不是毫秒：换音色、重新配音之后朗读长短全变，
  /// 记毫秒就得逐镜重调；记词区间则切点不变、时长自动重算。
  /// 这与 [SubtitleScreen] 是同一套模型——它们本来就该在同一个坐标系里，
  /// 此前一个记「第几个字」一个记「多少毫秒」，所以永远对不齐。
  ///
  /// **两端都要记**：字幕屏连续覆盖整句，下一屏的起点就是本屏的终点，
  /// 只记 startWord 够用；镜头之间夹着自由镜、还允许留空隙，推不出终点
  final int? startWord;
  final int? endWord;

  /// 这一镜是不是划词绑上去的
  bool get boundToWords => startWord != null && endWord != null;

  /// 【旧数据】曾经字幕写在镜头上，现在字幕屏挂在行上（见
  /// [ScriptLine.subtitleScreens]）。这里只保留读取，供打开老方案时
  /// 一次性迁移成屏；新写入一律不再产生它
  final String? legacySubtitleText;

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
    this.sourceVolume,
    this.startWord,
    this.endWord,
    this.legacySubtitleText,
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
    int? startWord,
    int? endWord,
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
        sourceVolume: sourceVolume,
        startWord: startWord ?? this.startWord,
        endWord: endWord ?? this.endWord,
        legacySubtitleText: legacySubtitleText,
      );

  /// 改这一镜的原声音量（null = 回到跟随全片）
  LineShot withSourceVolume(double? v) => LineShot(
        materialId: materialId,
        name: name,
        voiceover: voiceover,
        sceneDescription: sceneDescription,
        thumbnailUrl: thumbnailUrl,
        fileKey: fileKey,
        durationMs: durationMs,
        trimStartMs: trimStartMs,
        speed: speed,
        allocMs: allocMs,
        localSource: localSource,
        sourceVolume: v?.clamp(0.0, 1.0),
        startWord: startWord,
        endWord: endWord,
        legacySubtitleText: legacySubtitleText,
      );

  static const _unsetAlloc = Object();

  /// 挂上实测时长（素材落地后量出来的）。其余字段原样
  LineShot withMeasuredDuration(int ms) => LineShot(
        materialId: materialId,
        name: name,
        voiceover: voiceover,
        sceneDescription: sceneDescription,
        thumbnailUrl: thumbnailUrl,
        fileKey: fileKey,
        durationMs: ms,
        trimStartMs: trimStartMs,
        speed: speed,
        allocMs: allocMs,
        localSource: localSource,
        sourceVolume: sourceVolume,
        startWord: startWord,
        endWord: endWord,
        legacySubtitleText: legacySubtitleText,
      );

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
        if (sourceVolume != null) 'sourceVolume': sourceVolume,
        if (startWord != null) 'startWord': startWord,
        if (endWord != null) 'endWord': endWord,
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
      startWord: raw['startWord'] is int ? raw['startWord'] as int : null,
      endWord: raw['endWord'] is int ? raw['endWord'] as int : null,
      sourceVolume: raw['sourceVolume'] is num
          ? (raw['sourceVolume'] as num).toDouble().clamp(0.0, 1.0)
          : null,
      legacySubtitleText:
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

  /// 这一行单独设的语速（火山口径：0 = 原速，100 = 2 倍速，-50 = 0.5 倍速）。
  /// **null = 没设过、跟随本片基调**——0 是「就要原速」，两者不是一回事，
  /// 否则单独把某一句调回原速就做不到（见 [ScriptDoc.speechRateOf]）
  final int? speechRate;

  /// 已生成的配音产物；null = 还没生成过
  final LineVoiceover? voiceover;

  /// 这一行的镜头序列（挑中的 miaoa 分镜，按播放顺序排）
  final List<LineShot> shots;

  /// 这一句在参考片里的区间（提取脚本时自动落；手写的行没有）
  final LineRef? reference;

  /// 行级字幕样式覆盖；null = 跟随全局（素材自带字幕位置不同时按行改）
  final SubtitleStyle? subtitleOverride;

  /// 这一行的字幕屏（切点 + 可选的文本覆盖）。null = 全自动
  /// （按标点/停顿/每屏字数上限分屏，镜头时长一改就重算）
  final List<SubtitleScreen>? subtitleScreens;

  ScriptLine({
    required this.id,
    required this.text,
    this.manualMs,
    List<String> tags = const [],
    this.voiceId,
    this.speechRate,
    this.voiceover,
    List<LineShot> shots = const [],
    this.reference,
    this.subtitleOverride,
    this.subtitleScreens,
  })  : tags = List.unmodifiable(tags),
        shots = List.unmodifiable(shots);

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
  /// 只按行自己判断的旧入口（不知道本片基调时用）。
  /// **新代码一律用 [ScriptDoc.voiceStateOf]**——基调换了，行上没单独设过的
  /// 那些配音就该算过期，不然会混出一条前后音色不一样的片子
  LineVoiceState get voiceState => voiceStateAgainst(
      voiceId: voiceId ?? voiceover?.voiceId,
      speechRate: speechRate ?? voiceover?.speechRate ?? 0);

  /// 拿一组**有效值**来判定这一行的配音新不新
  LineVoiceState voiceStateAgainst({
    required String? voiceId,
    required int speechRate,
  }) {
    final vo = voiceover;
    if (vo == null) return LineVoiceState.none;
    final fresh = vo.sourceText == text.trim() &&
        vo.voiceId == (voiceId ?? vo.voiceId) &&
        vo.speechRate == speechRate;
    return fresh ? LineVoiceState.fresh : LineVoiceState.stale;
  }

  ScriptLine _copy({
    String? text,
    Object? manualMs = _unset,
    List<String>? tags,
    Object? voiceId = _unset,
    Object? speechRate = _unset,
    Object? voiceover = _unset,
    List<LineShot>? shots,
    Object? subtitleOverride = _unset,
    Object? subtitleScreens = _unset,
  }) =>
      ScriptLine(
        id: id,
        text: text ?? this.text,
        manualMs: manualMs == _unset ? this.manualMs : manualMs as int?,
        tags: tags ?? this.tags,
        voiceId: voiceId == _unset ? this.voiceId : voiceId as String?,
        speechRate:
            speechRate == _unset ? this.speechRate : speechRate as int?,
        voiceover:
            voiceover == _unset ? this.voiceover : voiceover as LineVoiceover?,
        shots: shots ?? this.shots,
        reference: reference,
        subtitleOverride: subtitleOverride == _unset
            ? this.subtitleOverride
            : subtitleOverride as SubtitleStyle?,
        subtitleScreens: subtitleScreens == _unset
            ? this.subtitleScreens
            : subtitleScreens as List<SubtitleScreen>?,
      );

  static const _unset = Object();

  ScriptLine withText(String next) => _copy(text: next);

  ScriptLine withManualMs(int? ms) => _copy(manualMs: ms);

  ScriptLine withTags(List<String> next) => _copy(tags: next);

  ScriptLine withVoiceId(String? id) => _copy(voiceId: id);

  /// null = 回到跟随本片基调
  ScriptLine withSpeechRate(int? rate) => _copy(speechRate: rate);

  /// 挂上新生成的配音。**不清旧文件**——旧音频的删除由调用方负责
  /// （生成成功后才删旧的，失败时旧配音还能听）
  ScriptLine withVoiceover(LineVoiceover? vo) => _copy(voiceover: vo);

  ScriptLine withShots(List<LineShot> next) => _copy(shots: next);

  ScriptLine withSubtitleOverride(SubtitleStyle? next) =>
      _copy(subtitleOverride: next);

  /// 换这一行的字幕屏（null = 恢复全自动）
  ScriptLine withSubtitleScreens(List<SubtitleScreen>? next) =>
      _copy(subtitleScreens: next);

  /// 词 → 原文字符区间（顺序扫描；对不上的词给 null）
  static List<(int, int)?> _wordOffsets(String src, List<VoiceWord> words) {
    final out = <(int, int)?>[];
    var pos = 0;
    for (final w in words) {
      final idx = w.text.isEmpty ? -1 : src.indexOf(w.text, pos);
      if (idx < 0) {
        out.add(null);
        pos = (pos + w.text.length).clamp(0, src.length);
        continue;
      }
      out.add((idx, idx + w.text.length));
      pos = idx + w.text.length;
    }
    return out;
  }

  /// 第 [from, to) 个词对应的原文片段；对不齐时退回词拼接
  static String _sliceSource(
      String src, List<(int, int)?> offsets, int from, int to) {
    int? start;
    int? end;
    for (var k = from; k < to && k < offsets.length; k++) {
      final o = offsets[k];
      if (o == null) continue;
      start ??= o.$1;
      end = o.$2;
    }
    if (start == null || end == null || end <= start) return '';
    return src.substring(start, end);
  }

  /// 自动切点落在划词边界上就不必重复添加（去重由 Set 负责，
  /// 这里只是让意图看得见）
  static bool _crossesBound(Set<int> bounds, int cut) => bounds.contains(cut);

  /// 这一句的配音**念岔了没有**（结尾卡住反复念、半截断掉、语速离谱）。
  /// null = 没问题或没证据可判。
  ///
  /// 用的是配音自带的词级时间戳（它本来就是 ASR 转写合成音频来的），
  /// 纯本地计算、不花钱。生成时已经拦过一道，这里管的是**早就躺在
  /// 方案里的那些**——不体检的话，坏配音要等人听到才发现（真机就是
  /// 这么撞上的）
  String? get voiceDefectText {
    final vo = voiceover;
    if (vo == null || type != ScriptLineType.voiced) return null;
    return voiceDefect(
        source: vo.sourceText, heard: vo.words, durationMs: vo.durationMs);
  }

  /// 这一行的字幕屏（行时间轴）：**屏是一等公民**——切点跟语言走、
  /// 与镜头无关；镜头时长怎么改，屏都自愈。
  ///
  /// 每屏的文本：人改过就用人的（'' = 这一屏不出字），没改过就用这几个
  /// 词拼出来的原文（标点一律剥掉——原片字幕就是无标点的堆字风格，
  /// 预览、卡片、成片四处同一份）。
  /// 每屏何时出现：这一屏第一个字说出口的时刻（第一屏从行首就在），
  /// 显示到下一屏出现为止；最后一屏留到行末尾。
  /// [maxChars] 是自动分屏的每屏字数上限——由**字号**推导
  /// （见 [SubtitleStyle.maxCharsPerScreen]）：知道生效样式的调用方
  /// （预览 / 卡片 / 导出）都把它传进来，字调大了屏就切得更碎、不出画。
  /// 不传时按本行覆盖样式或默认样式算
  List<({int startMs, int endMs, String text})> subtitleScreensAt(
      {int? maxChars}) {
    final chars =
        maxChars ?? (subtitleOverride ?? const SubtitleStyle()).maxCharsPerScreen;
    final vo = voiceover;
    if (type != ScriptLineType.voiced || vo == null) return const [];
    // 行长 = 画面总长（镜头 alloc 之和）；还没配镜头就用配音时长
    var lineSpan = 0;
    for (final s in shots) {
      lineSpan += s.allocMs ?? 0;
    }
    if (lineSpan <= 0) lineSpan = vo.durationMs;
    if (lineSpan <= 0) return const [];
    final words = vo.words;
    if (words.isEmpty) {
      // 老配音没有逐字时间戳：仍然分屏（26 个字堆在画面上是不合格的），
      // 只是切点靠语言与字数、时间按字数比例摊——这是**说得出口的降级**，
      // 界面上会写明「按字数均分」，重新生成配音后就有逐字时间了
      final src = vo.sourceText.trim().isNotEmpty ? vo.sourceText : text;
      final parts = [
        for (final p in splitTextByLength(src.trim(), maxChars: chars))
          if (stripPunctuation(p).isNotEmpty) p,
      ];
      if (parts.isEmpty) return const [];
      final total = parts.fold<int>(0, (n, p) => n + p.length);
      final out = <({int startMs, int endMs, String text})>[];
      var cursor = 0;
      for (var i = 0; i < parts.length; i++) {
        final end = i == parts.length - 1
            ? lineSpan
            : cursor +
                (lineSpan * parts[i].length / total).round().clamp(1, lineSpan);
        out.add((
          startMs: cursor,
          endMs: end.clamp(cursor, lineSpan),
          text: stripPunctuation(parts[i].trim())
        ));
        cursor = end;
      }
      return out;
    }
    final sentence = AsrSentence(
      startMs: 0,
      endMs: vo.durationMs,
      text: vo.sourceText,
      words: [
        for (final w in words)
          AsrWord(text: w.text, startMs: w.startMs, endMs: w.endMs),
      ],
    );
    // 切点：人切过就用人的，否则按语言节奏自动切。
    //
    // **划词建的镜头会把边界让给字幕**：一次操作同时定下画面和字幕的
    // 切点，字幕不会再跟配音脱节（真机数据里有一行「字幕停在 8 个字上、
    // 配音还在念后面 18 个字」，就是因为改字幕时改不了切点）。
    // 中间的自由段自成一屏——那里有几个镜头是画面的事，字幕不必跟着碎
    final manual = subtitleScreens;
    final boundCuts = <int>{
      for (final shot in shots)
        if (shot.boundToWords) ...[shot.startWord!, shot.endWord!],
    };
    final cuts = <int>{
      0,
      ...(manual != null
              ? manual.map((s) => s.startWord).where((w) => w > 0)
              : [
                  ...boundCuts,
                  // 划词镜之内字太多时照样细分：可读性是硬要求，
                  // 但细分点落在划词边界之内，不会跨出去
                  ...autoScreenCuts(sentence, maxChars: chars)
                      .where((w) => !_crossesBound(boundCuts, w)),
                ])
          .where((w) => w > 0 && w < words.length),
    }.toList()
      ..sort();
    // 每个词在原文里的字符区间（对不上给 null）
    final src = vo.sourceText.trim().isNotEmpty ? vo.sourceText : text;
    final offsets = _wordOffsets(src, words);
    final out = <({int startMs, int endMs, String text})>[];
    for (var i = 0; i < cuts.length; i++) {
      final from = cuts[i];
      final to = i + 1 < cuts.length ? cuts[i + 1] : words.length;
      if (to <= from) continue;
      // 人改过这一屏的字就用人的；'' = 这一屏不出字
      final override = manual != null && i < manual.length
          ? manual[i].text
          : null;
      // 屏文本**优先从原文切片**：ASR 词表会把「69.9一」并成一个词
      // "69.91"，照词拼接就把价格写错了（进入成片的字不许凭空错）。
      // 对不齐时才退回词拼接
      var raw = override ?? _sliceSource(src, offsets, from, to);
      if (raw.isEmpty && override == null) {
        raw = [for (var k = from; k < to; k++) words[k].text].join();
      }
      final t = stripPunctuation(raw.trim());
      final start = i == 0 ? 0 : words[from].startMs.clamp(0, lineSpan);
      final end = (i + 1 < cuts.length
              ? words[cuts[i + 1]].startMs
              : lineSpan)
          .clamp(0, lineSpan);
      if (end <= start || t.isEmpty) continue;
      out.add((startMs: start, endMs: end, text: t));
    }
    return out;
  }

  /// 兼容名：预览/卡片/导出都读这一份（曾经按镜头切，现在按屏）
  List<({int startMs, int endMs, String text})> get shotSubtitleSegments =>
      subtitleScreensAt();


  /// 在行时间轴 [atMs] 处切一刀（打轴/回车分屏都走它）：
  /// 找到这一刻正在说的那个词，从它开始另起一屏。已经是切点就原样返回
  ScriptLine cutSubtitleAt(int atMs, {int? maxChars}) {
    final vo = voiceover;
    if (vo == null || vo.words.isEmpty) return this;
    final words = vo.words;
    var idx = -1;
    for (var i = 0; i < words.length; i++) {
      if (words[i].startMs >= atMs) {
        idx = i;
        break;
      }
    }
    if (idx <= 0) return this;
    final current = _screensOrAuto(maxChars: maxChars);
    if (current.any((s) => s.startWord == idx)) return this;
    final next = [...current, SubtitleScreen(startWord: idx)]
      ..sort((a, b) => a.startWord.compareTo(b.startWord));
    return withSubtitleScreens(next);
  }

  /// 把第 [screenIndex] 屏并回上一屏（删这一刀）
  ScriptLine mergeSubtitleScreen(int screenIndex, {int? maxChars}) {
    final current = _screensOrAuto(maxChars: maxChars);
    if (screenIndex <= 0 || screenIndex >= current.length) return this;
    return withSubtitleScreens([
      for (var i = 0; i < current.length; i++)
        if (i != screenIndex) current[i],
    ]);
  }

  /// 改第 [screenIndex] 屏的字（null = 这屏回到原文，'' = 这屏不出字）
  ScriptLine setSubtitleScreenText(int screenIndex, String? text,
      {int? maxChars}) {
    final current = _screensOrAuto(maxChars: maxChars);
    if (screenIndex < 0 || screenIndex >= current.length) return this;
    return withSubtitleScreens([
      for (var i = 0; i < current.length; i++)
        if (i == screenIndex) current[i].copyWith(text: text) else current[i],
    ]);
  }

  /// 当前的屏切点：人切过就是人的，否则把自动结果**固化一次**
  /// （人一动就成为「已手改」，这一行从此按人的切点走）
  List<SubtitleScreen> _screensOrAuto({int? maxChars}) {
    final chars =
        maxChars ?? (subtitleOverride ?? const SubtitleStyle()).maxCharsPerScreen;
    final manual = subtitleScreens;
    if (manual != null) return manual;
    final vo = voiceover;
    if (vo == null || vo.words.isEmpty) {
      return const [SubtitleScreen(startWord: 0)];
    }
    final cuts = autoScreenCuts(
        maxChars: chars,
        AsrSentence(
          startMs: 0,
          endMs: vo.durationMs,
          text: vo.sourceText,
          words: [
            for (final w in vo.words)
              AsrWord(text: w.text, startMs: w.startMs, endMs: w.endMs),
          ],
        ));
    return [
      const SubtitleScreen(startWord: 0),
      for (final c in cuts) SubtitleScreen(startWord: c),
    ];
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
        if (speechRate != null) 'speechRate': speechRate,
        if (voiceover != null) 'voiceover': voiceover!.toJson(),
        if (shots.isNotEmpty) 'shots': [for (final s in shots) s.toJson()],
        if (reference != null) 'reference': reference!.toJson(),
        if (subtitleOverride != null)
          'subtitleOverride': subtitleOverride!.toJson(),
        if (subtitleScreens != null)
          'subtitleScreens': [
            for (final sc in subtitleScreens!) sc.toJson(),
          ],
      };

  /// 【旧数据迁移】老方案把字幕写在镜头上（LineShot.subtitleText）。
  /// 打开时一次性折算成行级字幕屏：镜头边界当切点、镜头上写的字当这屏
  /// 的文本；相邻镜头写了同一句就不切（原来它们本就连成一条）。
  /// 迁移完屏跟语言走，改镜头时长不再影响字幕——但用户写过的字一个不丢
  static ScriptLine _migrateLegacyShotSubtitles(ScriptLine line) {
    if (line.subtitleScreens != null) return line;
    if (!line.shots.any((s) => s.legacySubtitleText != null)) return line;
    final words = line.voiceover?.words ?? const <VoiceWord>[];
    if (words.isEmpty) return line;
    final screens = <SubtitleScreen>[];
    var shotStart = 0;
    String? prevText;
    for (var i = 0; i < line.shots.length; i++) {
      final shot = line.shots[i];
      final t = shot.legacySubtitleText;
      final sameAsPrev = i > 0 && t == prevText;
      if (!sameAsPrev) {
        var idx = 0;
        if (i > 0) {
          idx = words.indexWhere((w) => w.startMs >= shotStart);
          if (idx <= 0) idx = -1; // 对不上就不切这一刀
        }
        if (idx >= 0 && !screens.any((sc) => sc.startWord == idx)) {
          screens.add(SubtitleScreen(startWord: idx, text: t));
        }
      }
      prevText = t;
      shotStart += shot.allocMs ?? 0;
    }
    if (screens.isEmpty || screens.first.startWord != 0) {
      screens.insert(0, const SubtitleScreen(startWord: 0));
    }
    return line.withSubtitleScreens(screens);
  }

  /// 宽松解析：一条坏行只丢它自己，不牵连整份脚本
  static ScriptLine? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    if (id is! String || id.isEmpty || text is! String) return null;
    return _migrateLegacyShotSubtitles(ScriptLine(
      id: id,
      text: text,
      manualMs: raw['manualMs'] is int ? raw['manualMs'] as int : null,
      tags: [
        if (raw['tags'] is List)
          for (final t in raw['tags'] as List)
            if (t is String) t,
      ],
      voiceId: raw['voiceId'] is String ? raw['voiceId'] as String : null,
      // null = 没设过、跟随本片基调（0 是「就要原速」，不是没设过）
      speechRate: raw['speechRate'] is int ? raw['speechRate'] as int : null,
      voiceover: LineVoiceover.tryFromJson(raw['voiceover']),
      shots: [
        if (raw['shots'] is List)
          for (final s in raw['shots'] as List) ?LineShot.tryFromJson(s),
      ],
      reference: LineRef.tryFromJson(raw['reference']),
      subtitleOverride: raw['subtitleOverride'] is Map
          ? SubtitleStyle.fromJson(raw['subtitleOverride'])
          : null,
      subtitleScreens: raw['subtitleScreens'] is List
          ? [
              for (final sc in raw['subtitleScreens'] as List)
                ?SubtitleScreen.tryFromJson(sc),
            ]
          : null,
    ));
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

  /// 三条声音轨的总控（原声 / 口播 / 配乐）与闪避设置。见 [SoundMix]
  final SoundMix mix;

  /// 本片默认音色。**null = 还没设过**——这正是「生成第一句配音前先卡住
  /// 让人选」的判据：撞运气用系统默认，不对就白烧一次 TTS。
  ///
  /// 与字幕样式同一个模式：行上没设就跟随它，设过就以行为准
  final String? defaultVoiceId;

  /// 本片默认语速（火山口径：0 = 原速）
  final int defaultSpeechRate;

  /// 口播段落把原声压到多少。
  ///
  /// **老字段名，语义没变**：它一直就是「配音行没单独设时原声出多大」，
  /// 只是以前被摆在主预览下面当总音量用——画面行不参与这条规则，
  /// 所以拉它对画面行永远没反应。现在总音量是 [mix]，这里回归本名
  double get sourceVolume => mix.duckedSourceVolume;

  ScriptDoc(
    List<ScriptLine> lines, {
    this.subtitle = SubtitleStyle.standard,
    List<ScriptBgmSegment> bgmSegments = const [],
    this.refVideoPath,
    this.mix = const SoundMix(),
    this.defaultVoiceId,
    this.defaultSpeechRate = 0,
  })  : lines = List.unmodifiable(lines),
        bgmSegments = List.unmodifiable(bgmSegments);

  /// 新脚本自带一个空行：编导打开就能写，不用先学会「加行」
  factory ScriptDoc.empty() => ScriptDoc([ScriptLine.create()]);

  /// 换行列表、保留全局设置（字幕/配乐/参考片跟文档走，不跟行操作走）
  ScriptDoc _withLines(List<ScriptLine> next) => ScriptDoc(next,
      subtitle: subtitle,
      bgmSegments: bgmSegments,
      refVideoPath: refVideoPath,
      mix: mix,
      defaultVoiceId: defaultVoiceId,
      defaultSpeechRate: defaultSpeechRate);

  ScriptDoc withSubtitle(SubtitleStyle next) => ScriptDoc(lines,
      subtitle: next,
      bgmSegments: bgmSegments,
      refVideoPath: refVideoPath,
      mix: mix,
      defaultVoiceId: defaultVoiceId,
      defaultSpeechRate: defaultSpeechRate);

  /// 换三条轨的总控
  ScriptDoc withMix(SoundMix next) => ScriptDoc(lines,
      subtitle: subtitle,
      bgmSegments: bgmSegments,
      refVideoPath: refVideoPath,
      mix: next,
      defaultVoiceId: defaultVoiceId,
      defaultSpeechRate: defaultSpeechRate);

  /// 换「口播时原声压到多少」。老调用点仍在用这个名字
  ScriptDoc withSourceVolume(double next) =>
      withMix(mix.copyWith(duckedSourceVolume: next));

  /// 这一镜实际该用多大的原声。**全软件只此一处**——显示、预览、行内播放、
  /// 成片必须是同一个数。
  ///
  /// 真机 bug 就出在有两处：画面行的滑杆按「跟随全片」显示（默认 0，写着
  /// 「静音」），预览却按满音量播。界面撒谎，人就去拖那根滑杆想修好它，
  /// 一拖就把一个显式的 0.0 写死在那一镜上——从此那一行真的哑了，
  /// 而且调全片也救不回来。
  double sourceVolumeFor(ScriptLine line, LineShot shot) =>
      mix.effectiveSource *
      (shot.sourceVolume ?? defaultSourceVolumeFor(line));

  /// 这一行实际用哪个音色。**全软件只此一处**：显示、生成、过期判定
  /// 读的都是它
  String? voiceIdOf(ScriptLine line) => line.voiceId ?? defaultVoiceId;

  /// 这一行实际用多快的语速。行上设成 0 是「就要原速」，压过基调
  int speechRateOf(ScriptLine line) => line.speechRate ?? defaultSpeechRate;

  /// 这一行的配音新不新——拿**有效值**比。
  ///
  /// 基调换了，行上没单独设过的那些配音就该算过期。不这么判的话，
  /// 改完默认音色，前 10 句还是旧音色、后 18 句是新的，混出一条
  /// 前后不一样的片子，而且最容易一路漏到成片
  LineVoiceState voiceStateOf(ScriptLine line) => line.voiceStateAgainst(
      voiceId: voiceIdOf(line), speechRate: speechRateOf(line));

  /// 换本片默认音色
  ScriptDoc withDefaultVoiceId(String? next) => ScriptDoc(lines,
      subtitle: subtitle,
      bgmSegments: bgmSegments,
      refVideoPath: refVideoPath,
      mix: mix,
      defaultVoiceId: next,
      defaultSpeechRate: defaultSpeechRate);

  /// **统一全片音色**：设成基调，并清掉各行单独设过的。
  ///
  /// 只设基调不清覆盖的话，之前单独试过音色的那几行会留在旧音色上，
  /// 混出一条前后不一样的片子——而人点的明明是「全片」
  ScriptDoc unifyVoice(String voiceId) => withDefaultVoiceId(voiceId)
      ._withLines([for (final l in lines) l.withVoiceId(null)]);

  /// 统一全片语速，规则同 [unifyVoice]
  ScriptDoc unifySpeechRate(int rate) => withDefaultSpeechRate(rate)
      ._withLines([for (final l in lines) l.withSpeechRate(null)]);

  /// 配音已经过期、需要重新生成的那些行（画面行不算——它本来就没有配音）。
  ///
  /// 换完基调要拿它去问人「已经生成的这几句要不要一起换」：不问的话，
  /// 前几句旧音色、后几句新音色，最容易一路漏到成片
  List<ScriptLine> get staleVoiceLines => [
        for (final l in lines)
          if (voiceStateOf(l) == LineVoiceState.stale) l,
      ];

  /// 换本片默认语速
  ScriptDoc withDefaultSpeechRate(int next) => ScriptDoc(lines,
      subtitle: subtitle,
      bgmSegments: bgmSegments,
      refVideoPath: refVideoPath,
      mix: mix,
      defaultVoiceId: defaultVoiceId,
      defaultSpeechRate: next);

  /// 口播轨该出多大（整轨一个数：口播段落之间不需要各自不同）
  double get voiceVolume => mix.effectiveVoice;

  /// 这一段配乐该出多大：**段上设的是相对值**，乘在配乐轨总音量上——
  /// 所以拉总音量，单独调过的段落也跟着变
  double bgmVolumeOf(double segmentVolume) =>
      mix.effectiveBgm * segmentVolume;

  /// 没单独设过时，这一行的原声该多大。
  ///
  /// 两种行的默认不一样，因为它们的声音来路不一样：
  ///
  /// - **配音行**：原声会和口播叠成两份声音，所以默认跟随全片基调
  ///   （基调本身默认 0 = 压住）
  /// - **画面行**：没有口播，它本来就靠素材出声——默认满音量。
  ///   **不跟随全片**：全片调到 0 是为了压住口播下的原声，
  ///   不该顺手把整条画面行也弄哑
  double defaultSourceVolumeFor(ScriptLine line) =>
      line.type == ScriptLineType.voiced && mix.duckSourceUnderVoice
          ? mix.duckedSourceVolume
          : 1.0;

  /// 只按镜头看的旧入口（不知道行的类型时用）。
  /// 新代码一律用 [sourceVolumeFor]——它才知道画面行和配音行的默认不同
  double sourceVolumeOf(LineShot shot) => shot.sourceVolume ?? sourceVolume;

  /// 按行 id 改某一镜的原声音量（null = 回到跟随全片）
  ScriptDoc setShotSourceVolumeById(
      String lineId, int shotIndex, double? volume) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) {
      if (shotIndex < 0 || shotIndex >= line.shots.length) return line;
      return line.withShots([
        for (var i = 0; i < line.shots.length; i++)
          if (i == shotIndex)
            line.shots[i].withSourceVolume(volume)
          else
            line.shots[i],
      ]);
    });
  }

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

  /// 素材落地后回填**实测时长**。
  ///
  /// 素材时长原本靠对着签名地址跑 ffprobe 探测，网络一抖就探不到；探不到
  /// 就是 null，而 null 在 [LineShot.availableMs] 里被当成「无限长」——
  /// 于是这条素材可以被分配任意长的坑位，成片里画面定格、预览里时间轴
  /// 缩水（真机踩过）。文件既然已经在本地，量一次就没有猜的余地了。
  ///
  /// 只回填**还不知道**的（已有值不动，那可能是用户认过的规格）。
  ScriptDoc withMeasuredDuration(int materialId, int durationMs) {
    if (durationMs <= 0) return this;
    var changed = false;
    final next = [
      for (final line in lines)
        if (line.shots.any((s) =>
            s.materialId == materialId &&
            s.localSource == null &&
            s.durationMs == null))
          () {
            changed = true;
            return line.withShots([
              for (final s in line.shots)
                if (s.materialId == materialId &&
                    s.localSource == null &&
                    s.durationMs == null)
                  s.withMeasuredDuration(durationMs)
                else
                  s,
            ]);
          }()
        else
          line,
    ];
    return changed ? _withLines(next) : this;
  }

  /// 按行 id 换标签
  ScriptDoc setTagsById(String lineId, List<String> tags) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withTags(tags));
  }

  /// 按行 id 改第 [screenIndex] 屏的字（null = 回到原文，'' = 这屏不出字）
  ScriptDoc setScreenTextById(String lineId, int screenIndex, String? text,
      {int? maxChars}) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index,
        (line) => line.setSubtitleScreenText(screenIndex, text, maxChars: maxChars));
  }

  /// 按行 id 把第 [screenIndex] 屏并回上一屏
  ScriptDoc mergeScreenById(String lineId, int screenIndex, {int? maxChars}) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index,
        (line) => line.mergeSubtitleScreen(screenIndex, maxChars: maxChars));
  }

  /// 按行 id 在行时间轴 [atMs] 处切一刀（打轴 / 拆屏）
  ScriptDoc cutScreenById(String lineId, int atMs, {int? maxChars}) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(
        index, (line) => line.cutSubtitleAt(atMs, maxChars: maxChars));
  }

  /// 按行 id 直接给定这一行的字幕屏（Agent 断句回填走这里）
  ScriptDoc setScreensById(String lineId, List<SubtitleScreen> screens) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withSubtitleScreens(screens));
  }

  /// 按行 id 让字幕恢复全自动（清掉切点与改字）
  ScriptDoc resetScreensById(String lineId) {
    final index = lines.indexWhere((l) => l.id == lineId);
    return _update(index, (line) => line.withSubtitleScreens(null));
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
        // 老字段照写：旧版本打开这份档，声音行为和以前完全一致
        if (sourceVolume > 0) 'sourceVolume': sourceVolume,
        if (mix.toJson().isNotEmpty) 'soundMix': mix.toJson(),
        if (defaultVoiceId != null) 'defaultVoiceId': defaultVoiceId,
        if (defaultSpeechRate != 0) 'defaultSpeechRate': defaultSpeechRate,
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
      // 老档只有 sourceVolume：它一直就是「口播时原声压到多少」，
      // 原样搬进闪避电平——升级前后已有片子的声音一个字节不变
      mix: raw['soundMix'] is Map
          ? SoundMix.fromJson(raw['soundMix'])
          : SoundMix(
              duckedSourceVolume: raw['sourceVolume'] is num
                  ? (raw['sourceVolume'] as num).toDouble()
                  : 0.0),
      refVideoPath: raw['refVideoPath'] is String
          ? raw['refVideoPath'] as String
          : null,
      // 老档没有基调：读出来是「还没设过」，行为和以前一样
      defaultVoiceId:
          raw['defaultVoiceId'] is String ? raw['defaultVoiceId'] as String : null,
      defaultSpeechRate: raw['defaultSpeechRate'] is int
          ? raw['defaultSpeechRate'] as int
          : 0,
    );
  }
}

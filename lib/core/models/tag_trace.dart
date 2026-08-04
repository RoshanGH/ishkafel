/// 一次 AI 打标的**过程量**：喂了什么、模型原样回了什么。
///
/// 为什么要存：打标是个黑箱，结果不对时无从判断是「数据没取对」还是「模型
/// 理解错了」。把输入与原始输出留在任务数据里，任何时候都能回看当时到底
/// 发生了什么，不必重跑一遍。
///
/// 体积可控：一条 96 秒素材约 57 个镜头，每条痕迹百来字，合计约 10KB。
class TagTrace {
  /// 送去理解的帧时间点（毫秒）。视觉层才有，台词层为空。
  final List<int> sampledAtMs;

  /// 那些帧在磁盘上的路径（analysis_work 下，分析后仍保留）
  final List<String> framePaths;

  /// 文本输入（台词层是该单元台词；视觉层为空）
  final String? textInput;

  /// 受控词表来自哪几个标签组
  final List<String> vocabularyGroups;

  /// 合并去重后的词表大小
  final int vocabularySize;

  /// 用户为这一层写的打标约束（一层一条）。标签不对时，「喂进去的约束是
  /// 什么」往往才是问题所在，因此和词表一起留痕。
  final String? prompt;

  /// 这次打标按维度分开的结果。界面上分维度显示，用户才看得出「场景判成了
  /// 什么、动作判成了什么」，而不是一堆混在一起的词。
  final Map<String, List<String>> tagsByDimension;

  /// 模型**原样**返回的内容，不做任何加工——解析出错时全靠它定位
  final String? rawReply;

  /// 这条痕迹产生的时刻
  final DateTime? at;

  const TagTrace({
    this.sampledAtMs = const [],
    this.framePaths = const [],
    this.textInput,
    this.vocabularyGroups = const [],
    this.vocabularySize = 0,
    this.prompt,
    this.tagsByDimension = const {},
    this.rawReply,
    this.at,
  });

  Map<String, dynamic> toJson() => {
        'sampledAtMs': sampledAtMs,
        'framePaths': framePaths,
        'textInput': textInput,
        'vocabularyGroups': vocabularyGroups,
        'vocabularySize': vocabularySize,
        'prompt': prompt,
        'tagsByDimension': tagsByDimension,
        'rawReply': rawReply,
        'at': at?.toIso8601String(),
      };

  /// 宽松解析：痕迹只是排障用的附加信息，缺字段或类型不符都不该让整条
  /// 镜头读不出来
  static TagTrace? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    return TagTrace(
      sampledAtMs: _ints(raw['sampledAtMs']),
      framePaths: _strings(raw['framePaths']),
      textInput: raw['textInput'] is String ? raw['textInput'] as String : null,
      vocabularyGroups: _strings(raw['vocabularyGroups']),
      vocabularySize: raw['vocabularySize'] is int ? raw['vocabularySize'] as int : 0,
      prompt: _prompt(raw),
      tagsByDimension: _stringListMap(raw['tagsByDimension']),
      rawReply: raw['rawReply'] is String ? raw['rawReply'] as String : null,
      at: raw['at'] is String ? DateTime.tryParse(raw['at'] as String) : null,
    );
  }

  /// 约束一度是**按维度**存的（每个标签组一条）。旧痕迹里那些不该就这么
  /// 看不见了——把它们接起来，回看时仍然知道当时喂进去的是什么。
  static String? _prompt(Map raw) {
    final current = raw['prompt'];
    if (current is String && current.trim().isNotEmpty) return current;
    final legacy = _stringMap(raw['dimensionPrompts']);
    if (legacy.isEmpty) return null;
    return [for (final e in legacy.entries) '${e.key}：${e.value}'].join('\n');
  }

  static List<int> _ints(Object? v) => v is! List
      ? const []
      : List.unmodifiable([
          for (final e in v)
            if (e is int) e,
        ]);

  static List<String> _strings(Object? v) => v is! List
      ? const []
      : List.unmodifiable([
          for (final e in v)
            if (e is String) e,
        ]);

  static Map<String, String> _stringMap(Object? v) => v is! Map
      ? const {}
      : Map.unmodifiable({
          for (final e in v.entries)
            if (e.key is String && e.value is String)
              e.key as String: e.value as String,
        });

  static Map<String, List<String>> _stringListMap(Object? v) => v is! Map
      ? const {}
      : Map.unmodifiable({
          for (final e in v.entries)
            if (e.key is String) e.key as String: _strings(e.value),
        });
}

/// 一个镜头切点是怎么定出来的（切分层的过程量）
class BoundaryTrace {
  /// ffmpeg 的相邻帧差分分数
  final double? sceneScore;

  /// 颜色直方图距离
  final double? histDistance;

  /// 判定结论：confirmed（两项指标直接确认）/ reviewed（灰区经画面复核保留）
  /// / manual（用户手动调过）
  final String? decision;

  const BoundaryTrace({this.sceneScore, this.histDistance, this.decision});

  Map<String, dynamic> toJson() => {
        'sceneScore': sceneScore,
        'histDistance': histDistance,
        'decision': decision,
      };

  static BoundaryTrace? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    return BoundaryTrace(
      sceneScore: _double(raw['sceneScore']),
      histDistance: _double(raw['histDistance']),
      decision: raw['decision'] is String ? raw['decision'] as String : null,
    );
  }

  static double? _double(Object? v) => v is num ? v.toDouble() : null;
}

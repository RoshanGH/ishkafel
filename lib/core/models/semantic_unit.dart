import 'package:collection/collection.dart';
import '../audio/material_audio.dart';
import 'shot.dart';
import 'tag_trace.dart';

/// 台词语义单元：以台词语义为准的切分单元，内部包含若干视觉镜头（不可变）
class SemanticUnit {
  final int index;
  final int startMs;
  final int endMs;
  final String transcript;
  final List<String> tags;

  /// 标签是否已经过期：这个单元被编辑过、标签还是编辑前打的。
  /// 不直接抹掉标签——重打是异步的，中间抹空会让用户以为标签丢了。
  final bool tagsStale;

  /// 这些标签是**人手改的**，不是模型打的。
  ///
  /// 重新打标时跳过它——人刚照着画面判断过，模型再打一遍等于把他的结论抹掉，
  /// 而且不问一声：他不会想到「我改的东西被一个后台步骤盖了」，
  /// 只会觉得改了没生效。想让模型重新接管，先把手改清掉。
  final bool tagsHandpicked;

  /// 这次打标的过程量（输入台词、词表、模型原样回复）
  final TagTrace? trace;
  final List<Shot> shots;

  /// 这个单元被**整体替换**时，放素材自己的哪一路声音。
  ///
  /// null = 原声（不分离、满音量），也就是这个功能出现之前的行为——
  /// 整体替换本来就是「画面和声音一起换掉」，那一段的口播来自素材。
  /// 手动加的单元尤其用得上改它：片头插一段素材，你多半只要画面，
  /// 里面别人说的话不该跟着播出来。
  ///
  /// **和镜头级那个不是一回事**：镜头替换只换画面、口播还是原片的，
  /// 素材声音是额外叠的一层，所以那边默认「不播放」。
  final MaterialAudioMode? wholeAudioMode;

  /// 整体替换时素材声音压到几成。null = 满音量（原来的行为）
  final double? wholeAudioVolume;

  /// 这个单元在**原片上有没有对应的一段**。
  ///
  /// 默认 true——分析切出来的单元都取自原片。false 只出现在用户**手动加**
  /// 的单元上：原片里没有它，画面只能来自挑到的素材，[startMs]/[endMs]
  /// 这时只是它在时间线上占的位置，不指向原片的任何一段。
  ///
  /// 谁需要它：导出与预览要知道「这一段没有原片可放，没挑素材就是真的缺东西」
  /// （不许拿黑帧顶上）；原声重剪要跳过它；抽帧、烧字幕同理。
  final bool hasSource;

  const SemanticUnit({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.transcript,
    this.tags = const [],
    this.tagsStale = false,
    this.tagsHandpicked = false,
    this.trace,
    this.shots = const [],
    this.hasSource = true,
    this.wholeAudioMode,
    this.wholeAudioVolume,
  });

  int get durationMs => endMs - startMs;

  /// 严格包含约束：所有镜头边界必须落在本单元范围内
  bool get shotsStrictlyNested =>
      shots.every((s) => s.startMs >= startMs && s.endMs <= endMs);

  SemanticUnit copyWith({
    int? index,
    int? startMs,
    int? endMs,
    String? transcript,
    List<String>? tags,
    bool? tagsStale,
    bool? tagsHandpicked,
    TagTrace? trace,
    List<Shot>? shots,
    bool? hasSource,
    MaterialAudioMode? wholeAudioMode,
    double? wholeAudioVolume,
  }) =>
      SemanticUnit(
        index: index ?? this.index,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        transcript: transcript ?? this.transcript,
        tags: tags ?? this.tags,
        tagsStale: tagsStale ?? this.tagsStale,
        tagsHandpicked: tagsHandpicked ?? this.tagsHandpicked,
        trace: trace ?? this.trace,
        shots: shots ?? this.shots,
        hasSource: hasSource ?? this.hasSource,
        wholeAudioMode: wholeAudioMode ?? this.wholeAudioMode,
        wholeAudioVolume: wholeAudioVolume ?? this.wholeAudioVolume,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'startMs': startMs,
        'endMs': endMs,
        'transcript': transcript,
        'tags': tags,
        'tagsStale': tagsStale,
        if (tagsHandpicked) 'tagsHandpicked': true,
        'shots': shots.map((s) => s.toJson()).toList(),
        'trace': trace?.toJson(),
        'hasSource': hasSource,
        // 只在设过时才写：没设过和「明确设成原声」在存档里要分得开
        if (wholeAudioMode != null) 'wholeAudioMode': wholeAudioMode!.name,
        if (wholeAudioVolume != null) 'wholeAudioVolume': wholeAudioVolume,
      };

  factory SemanticUnit.fromJson(Map<String, dynamic> json) => SemanticUnit(
        index: json['index'] as int,
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        transcript: json['transcript'] as String,
        // 缺失/为 null 时兜底为空列表（与 Shot.tags 同款兼容）：
        // 硬转换会让整条任务在 findAll 里被跳过，用户看到的是「任务不见了」
        tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
        tagsStale: json['tagsStale'] == true,
        // 存量存档里没有这个字段——那时的标签都是模型打的
        tagsHandpicked: json['tagsHandpicked'] == true,
        shots: (json['shots'] as List<dynamic>?)
                ?.map((e) => Shot.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        trace: TagTrace.tryFromJson(json['trace']),
        // 存量存档里没有这个字段——它们的单元都是分析切出来的，都有原片来源。
        // 缺失时必须兜底为 true，兜成 false 会让老任务整条以为原片不见了
        hasSource: json['hasSource'] != false,
        wholeAudioMode:
            MaterialAudioMode.byName(json['wholeAudioMode'] as String?),
        wholeAudioVolume: (json['wholeAudioVolume'] as num?)?.toDouble(),
      );

  static const _listEq = ListEquality<Object>();

  @override
  bool operator ==(Object other) =>
      other is SemanticUnit &&
      other.index == index &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.transcript == transcript &&
      _listEq.equals(other.tags, tags) &&
      other.tagsStale == tagsStale &&
      _listEq.equals(other.shots, shots);

  @override
  int get hashCode => Object.hash(index, startMs, endMs, transcript,
      Object.hashAll(tags), tagsStale, Object.hashAll(shots));
}

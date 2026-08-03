import 'package:collection/collection.dart';
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

  /// 这次打标的过程量（输入台词、词表、模型原样回复）
  final TagTrace? trace;
  final List<Shot> shots;

  const SemanticUnit({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.transcript,
    this.tags = const [],
    this.tagsStale = false,
    this.trace,
    this.shots = const [],
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
    TagTrace? trace,
    List<Shot>? shots,
  }) =>
      SemanticUnit(
        index: index ?? this.index,
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        transcript: transcript ?? this.transcript,
        tags: tags ?? this.tags,
        tagsStale: tagsStale ?? this.tagsStale,
        trace: trace ?? this.trace,
        shots: shots ?? this.shots,
      );

  Map<String, dynamic> toJson() => {
        'index': index,
        'startMs': startMs,
        'endMs': endMs,
        'transcript': transcript,
        'tags': tags,
        'tagsStale': tagsStale,
        'shots': shots.map((s) => s.toJson()).toList(),
        'trace': trace?.toJson(),
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
        shots: (json['shots'] as List<dynamic>?)
                ?.map((e) => Shot.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        trace: TagTrace.tryFromJson(json['trace']),
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

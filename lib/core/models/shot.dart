import 'package:collection/collection.dart';

/// 视觉镜头：语义单元内部的画面切换单元（不可变）
class Shot {
  final int startMs;
  final int endMs;
  final List<String> tags;

  /// 这个镜头拍的是什么（AI 按 1 FPS 采样多帧后给出的一句话）。
  ///
  /// 两个用处：检查器里让用户一眼看懂这个镜头；以及阶段②「画面描述」检索
  /// 的检索键——miaoa 的 `--by content` 就是按画面描述做语义搜索，
  /// 拿台词去搜画面（改造前的做法）本来就搜不准。
  final String? description;

  /// 标签/描述是否已过期：这个镜头的边界被改过，但用户选择了暂不重新打标
  final bool tagsStale;

  const Shot({
    required this.startMs,
    required this.endMs,
    this.tags = const [],
    this.description,
    this.tagsStale = false,
  });

  int get durationMs => endMs - startMs;

  Shot copyWith({
    int? startMs,
    int? endMs,
    List<String>? tags,
    String? description,
    bool? tagsStale,
  }) =>
      Shot(
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        tags: tags ?? this.tags,
        description: description ?? this.description,
        tagsStale: tagsStale ?? this.tagsStale,
      );

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'tags': tags,
        'description': description,
        'tagsStale': tagsStale,
      };

  factory Shot.fromJson(Map<String, dynamic> json) => Shot(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
        description: json['description'] as String?,
        tagsStale: json['tagsStale'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is Shot &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.description == description &&
      other.tagsStale == tagsStale &&
      const ListEquality<String>().equals(other.tags, tags);

  @override
  int get hashCode => Object.hash(
      startMs, endMs, description, tagsStale, Object.hashAll(tags));
}

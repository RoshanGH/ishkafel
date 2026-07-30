import 'package:collection/collection.dart';

/// 视觉镜头：语义单元内部的画面切换单元（不可变）
class Shot {
  final int startMs;
  final int endMs;
  final List<String> tags;

  const Shot({
    required this.startMs,
    required this.endMs,
    this.tags = const [],
  });

  int get durationMs => endMs - startMs;

  Shot copyWith({int? startMs, int? endMs, List<String>? tags}) => Shot(
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        tags: tags ?? this.tags,
      );

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'tags': tags,
      };

  factory Shot.fromJson(Map<String, dynamic> json) => Shot(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
      );

  @override
  bool operator ==(Object other) =>
      other is Shot &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      const ListEquality<String>().equals(other.tags, tags);

  @override
  int get hashCode => Object.hash(startMs, endMs, Object.hashAll(tags));
}

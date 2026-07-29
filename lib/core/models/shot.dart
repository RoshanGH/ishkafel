/// 视觉镜头：语义单元内部的画面切换单元（不可变）
class Shot {
  final int startMs;
  final int endMs;

  const Shot({required this.startMs, required this.endMs});

  int get durationMs => endMs - startMs;

  Map<String, dynamic> toJson() => {'startMs': startMs, 'endMs': endMs};

  factory Shot.fromJson(Map<String, dynamic> json) =>
      Shot(startMs: json['startMs'] as int, endMs: json['endMs'] as int);

  @override
  bool operator ==(Object other) =>
      other is Shot && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);
}

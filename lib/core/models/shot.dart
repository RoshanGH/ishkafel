import 'package:collection/collection.dart';

import 'tag_trace.dart';

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

  /// 这一镜画面里露出的产品是谁家的（打标时顺手读包装和 logo）。
  ///
  /// **它是「本片是什么品牌」的唯一可靠来源**：产品露出镜头不能跨品牌换，
  /// 而判断候选对不对得上，总得有个参照。任务名和项目名靠不住（改名、
  /// 合并项目），描述里也从来不写品牌——只有画面本身知道。
  /// null = 这一镜没有产品露出，或认不出牌子。
  final String? productBrand;

  /// 标签/描述是否已过期：这个镜头的边界被改过，但用户选择了暂不重新打标
  final bool tagsStale;

  /// 这次打标的过程量（喂了哪些帧、什么词表、模型原样回了什么）
  final TagTrace? trace;

  /// 这个镜头的起点是怎么定出来的（画面差异分数、是否经过画面复核）
  final BoundaryTrace? boundaryTrace;

  const Shot({
    required this.startMs,
    required this.endMs,
    this.tags = const [],
    this.description,
    this.productBrand,
    this.tagsStale = false,
    this.trace,
    this.boundaryTrace,
  });

  int get durationMs => endMs - startMs;

  Shot copyWith({
    int? startMs,
    int? endMs,
    List<String>? tags,
    String? description,
    String? productBrand,
    bool? tagsStale,
    TagTrace? trace,
    BoundaryTrace? boundaryTrace,
  }) =>
      Shot(
        startMs: startMs ?? this.startMs,
        endMs: endMs ?? this.endMs,
        tags: tags ?? this.tags,
        description: description ?? this.description,
        productBrand: productBrand ?? this.productBrand,
        tagsStale: tagsStale ?? this.tagsStale,
        trace: trace ?? this.trace,
        boundaryTrace: boundaryTrace ?? this.boundaryTrace,
      );

  Map<String, dynamic> toJson() => {
        'startMs': startMs,
        'endMs': endMs,
        'tags': tags,
        'description': description,
        if (productBrand != null) 'productBrand': productBrand,
        'tagsStale': tagsStale,
        'trace': trace?.toJson(),
        'boundaryTrace': boundaryTrace?.toJson(),
      };

  factory Shot.fromJson(Map<String, dynamic> json) => Shot(
        startMs: json['startMs'] as int,
        endMs: json['endMs'] as int,
        tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
        description: json['description'] as String?,
        productBrand: json['productBrand'] as String?,
        tagsStale: json['tagsStale'] as bool? ?? false,
        trace: TagTrace.tryFromJson(json['trace']),
        boundaryTrace: BoundaryTrace.tryFromJson(json['boundaryTrace']),
      );

  @override
  bool operator ==(Object other) =>
      other is Shot &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.description == description &&
      other.productBrand == productBrand &&
      other.tagsStale == tagsStale &&
      const ListEquality<String>().equals(other.tags, tags);

  @override
  int get hashCode => Object.hash(
      startMs, endMs, description, productBrand, tagsStale,
      Object.hashAll(tags));
}

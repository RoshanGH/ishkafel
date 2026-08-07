import 'package:collection/collection.dart';

/// 一条可用作 BGM 的音频素材（来自 miaoa 音频库）
class BgmMaterial {
  final int id;
  final String name;
  final int durationMs;

  /// 试听地址（签名 URL，有时效；拿不到时为 null，卡片上不给试听按钮）
  final String? previewUrl;

  final List<String> tags;

  /// 这条音频里有人说话。带解说的音频压在成片下面会和原片口播打架，
  /// 必须在卡片上标出来，不能让用户听一遍才发现。
  final bool hasSpeech;

  const BgmMaterial({
    required this.id,
    required this.name,
    required this.durationMs,
    required this.previewUrl,
    this.tags = const [],
    this.hasSpeech = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'durationMs': durationMs,
        'previewUrl': previewUrl,
        'tags': tags,
        'hasSpeech': hasSpeech,
      };

  /// 宽松解析：外部数据，畸形只丢这一条
  static BgmMaterial? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! int) return null;
    return BgmMaterial(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '未命名音频',
      durationMs: raw['durationMs'] is int ? raw['durationMs'] as int : 0,
      previewUrl: raw['previewUrl'] is String ? raw['previewUrl'] as String : null,
      tags: (raw['tags'] as List<dynamic>?)?.whereType<String>().toList() ??
          const [],
      hasSpeech: raw['hasSpeech'] == true,
    );
  }
}

/// 素材时长与区间时长对不上时怎么办
enum BgmFit {
  /// 素材比区间长，多出来的裁掉
  cut('裁掉多余部分'),

  /// 素材比区间短，循环补齐
  loop('循环播放补齐'),

  /// 差得可以忽略
  exact('时长刚好');

  final String label;
  const BgmFit(this.label);
}

/// 一段配乐：铺在连续的一串**视觉镜头**上。
///
/// 用镜头下标而不是毫秒：用户拖边界时镜头会伸缩，按毫秒存的区间会跟画面
/// 错位；按镜头存则天然跟着走。下标是**全片打平**的（跨台词语义单元连续
/// 编号）——配乐本来就不跟台词走，一段情绪往往横跨好几句话。
class BgmSegment {
  final int startShot;
  final int endShot;
  final BgmMaterial material;
  final BgmFit fit;

  /// 这一段配乐压到原始音量的几成（0~1）。
  ///
  /// **每段独立**：用户在不同段铺不同的曲子，有的本来就响、有的很闷，
  /// 一个全局值必然有一段不合适。
  final double volume;

  /// 默认压到四分之一——垫乐盖过台词是最常见的翻车方式，而这条片子的
  /// 主体是口播
  static const double defaultVolume = 0.25;

  const BgmSegment({
    required this.startShot,
    required this.endShot,
    required this.material,
    required this.fit,
    this.volume = defaultVolume,
  });

  /// 夹回 0~1。构造函数是 const 的（很多地方直接 `const BgmSegment(...)`），
  /// 夹取只能放在入口：来自界面的滑块、来自存档的脏数据。
  static double clampVolume(double v) => v < 0
      ? 0
      : v > 1
          ? 1
          : v;

  bool covers(int shotIndex) => shotIndex >= startShot && shotIndex <= endShot;

  BgmSegment copyWith({int? startShot, int? endShot, double? volume}) =>
      BgmSegment(
        startShot: startShot ?? this.startShot,
        endShot: endShot ?? this.endShot,
        material: material,
        fit: fit,
        volume: volume ?? this.volume,
      );

  Map<String, dynamic> toJson() => {
        'startShot': startShot,
        'endShot': endShot,
        'material': material.toJson(),
        'fit': fit.name,
        'volume': volume,
      };

  static BgmSegment? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = raw['startShot'];
    final end = raw['endShot'];
    if (start is! int || end is! int || end < start) return null;
    final material = BgmMaterial.tryFromJson(raw['material']);
    if (material == null) return null;
    final fit = BgmFit.values.firstWhereOrNull((f) => f.name == raw['fit']);
    final volume = raw['volume'];
    return BgmSegment(
      startShot: start,
      endShot: end,
      material: material,
      fit: fit ?? BgmFit.exact,
      // 老存档没有这个字段；脏数据由构造函数夹回 0~1
      volume: volume is num ? clampVolume(volume.toDouble()) : defaultVolume,
    );
  }
}

/// 全片的配乐方案（不可变）。
///
/// 段之间互不重叠：一个镜头同时响两段配乐没有意义，因此新段直接压住旧段，
/// 被压住的部分从旧段里让出来。「改就是改」——留下看不见的半截，用户下次
/// 拖动时会莫名其妙地又听到它。
class BgmPlan {
  final List<BgmSegment> segments;

  /// 上一次操作把相邻同素材段合并、并因此改掉了某一段的音量时的说明。
  /// 不是方案的一部分，只在这一次操作后拿来提示用户
  final String? mergedVolumeNotice;

  const BgmPlan(this.segments, {this.mergedVolumeNotice});

  static const empty = BgmPlan([]);

  bool get isEmpty => segments.isEmpty;

  /// 这个镜头归哪一段管；没有配乐时返回 null
  BgmSegment? segmentAt(int shotIndex) =>
      segments.firstWhereOrNull((s) => s.covers(shotIndex));

  /// 差在这个范围内就当「刚好」。差 0.2 秒还写「会循环播放」是在吓唬用户。
  static const int fitToleranceMs = 500;

  static BgmFit fitFor({
    required int materialDurationMs,
    required int rangeMs,
  }) {
    final diff = materialDurationMs - rangeMs;
    if (diff.abs() <= fitToleranceMs) return BgmFit.exact;
    return diff > 0 ? BgmFit.cut : BgmFit.loop;
  }

  /// 把 [material] 铺到 [startShot]..[endShot] 上。
  ///
  /// [shotRangeMs] 是这段镜头的实际总时长，用来判断裁还是循环——调用方
  /// 拿得到 units，这里不重复算一遍。
  BgmPlan assign({
    required int startShot,
    required int endShot,
    required BgmMaterial material,
    required int shotRangeMs,
    double volume = BgmSegment.defaultVolume,
  }) {
    // 用户可能从右往左拖
    final from = startShot <= endShot ? startShot : endShot;
    final to = startShot <= endShot ? endShot : startShot;

    final next = <BgmSegment>[];
    for (final old in segments) {
      // 完全被压住：整段让出去
      if (old.startShot >= from && old.endShot <= to) continue;
      // 完全不相干：原样保留
      if (old.endShot < from || old.startShot > to) {
        next.add(old);
        continue;
      }
      // 部分重叠：左右各留下不重叠的那截（新段落在中间时会劈成两半）
      if (old.startShot < from) {
        next.add(old.copyWith(endShot: from - 1));
      }
      if (old.endShot > to) {
        next.add(old.copyWith(startShot: to + 1));
      }
    }
    next.add(BgmSegment(
      startShot: from,
      endShot: to,
      material: material,
      fit: fitFor(materialDurationMs: material.durationMs, rangeMs: shotRangeMs),
      volume: BgmSegment.clampVolume(volume),
    ));
    next.sort((a, b) => a.startShot.compareTo(b.startShot));
    // 刚放上去的这一段的音量是「最后设的」，合并时由它覆盖整段
    return _merged(next, winningVolume: BgmSegment.clampVolume(volume));
  }

  /// 把这个镜头区间从所有配乐段里**抠掉**。
  ///
  /// 整体替换一个台词语义单元时用：那一段的画面、口播、配乐全部来自候选素材，
  /// 原来铺在它上面的配乐在这一段就不存在了。抠完可能是截断、劈成两段、
  /// 或整段消失。
  BgmPlan carveOutShots(int fromShot, int toShot) {
    final from = fromShot <= toShot ? fromShot : toShot;
    final to = fromShot <= toShot ? toShot : fromShot;
    final next = <BgmSegment>[];
    for (final s in segments) {
      // 完全被盖住：整段没了
      if (s.startShot >= from && s.endShot <= to) continue;
      // 不相干：原样
      if (s.endShot < from || s.startShot > to) {
        next.add(s);
        continue;
      }
      // 左右各留下不重叠的那截；被抠的部分落在中间时劈成两段
      if (s.startShot < from) next.add(s.copyWith(endShot: from - 1));
      if (s.endShot > to) next.add(s.copyWith(startShot: to + 1));
    }
    next.sort((a, b) => a.startShot.compareTo(b.startShot));
    return BgmPlan(List.unmodifiable(next));
  }

  /// 相邻的同一首曲子并成一段——不在接缝处从头重播。
  ///
  /// 音量取**最后设的那个**（[winningVolume]）：用户刚在选择浮层里调过，
  /// 被前一段盖掉会让人觉得「我刚设的没生效」。因此确实改到了别的段时，
  /// 通过 [mergedVolumeNotice] 说一声，不静默。
  static BgmPlan _merged(List<BgmSegment> sorted, {double? winningVolume}) {
    final out = <BgmSegment>[];
    var changedVolume = false;
    for (final s in sorted) {
      final last = out.isEmpty ? null : out.last;
      if (last != null &&
          last.material.id == s.material.id &&
          last.endShot + 1 == s.startShot) {
        final volume = winningVolume ?? last.volume;
        if (last.volume != volume || s.volume != volume) changedVolume = true;
        out[out.length - 1] =
            last.copyWith(endShot: s.endShot, volume: volume);
        continue;
      }
      out.add(s);
    }
    return BgmPlan(
      List.unmodifiable(out),
      mergedVolumeNotice: changedVolume && winningVolume != null
          ? '已与相邻的同一段配乐合并，整段音量设为 '
              '${(winningVolume * 100).round()}%'
          : null,
    );
  }

  /// 只改某一段的音量，不换曲子。[startShot] 用来认段；找不到就原样返回。
  BgmPlan withVolume({required int startShot, required double volume}) =>
      BgmPlan(List.unmodifiable([
        for (final s in segments)
          if (s.startShot == startShot)
            s.copyWith(volume: BgmSegment.clampVolume(volume))
          else
            s,
      ]));

  /// 移除覆盖 [shotIndex] 的那一段；没有就原样返回
  BgmPlan removeAt(int shotIndex) {
    final target = segmentAt(shotIndex);
    if (target == null) return this;
    return BgmPlan(List.unmodifiable(
        segments.where((s) => !identical(s, target)).toList()));
  }

  List<Map<String, dynamic>> toJson() =>
      [for (final s in segments) s.toJson()];

  /// 宽松解析：一段畸形只丢那一段。任务 JSON 里一处解析失败就让整条任务
  /// 从列表消失，用户看到的是「我的任务不见了」。
  static BgmPlan fromJson(Object? raw) {
    if (raw is! List) return empty;
    final parsed = <BgmSegment>[];
    for (final item in raw) {
      final segment = BgmSegment.tryFromJson(item);
      if (segment != null) parsed.add(segment);
    }
    parsed.sort((a, b) => a.startShot.compareTo(b.startShot));
    return BgmPlan(List.unmodifiable(parsed));
  }
}

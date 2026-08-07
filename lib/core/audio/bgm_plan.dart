import 'package:collection/collection.dart';

import '../log/app_log.dart';
import '../models/semantic_unit.dart';

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
  /// **按台词语义单元对齐，不是镜头**。
  ///
  /// 整体替换之后单元还在（只是时长变了），镜头没了——那一整段变成一条候选
  /// 素材。按镜头记的区间在那一刻就悬空了；按单元记则永远有意义。
  ///
  /// 代价：不能给单元内的部分镜头铺配乐（真机上 U4 是 40 秒 20 个镜头，
  /// 以后只能整段铺或整段不铺）。垫乐本来就是大段铺的，这个粒度够用。
  final int startUnit;
  final int endUnit;

  /// 这一段选中的曲子们，**互为备选**（不是叠着放）。
  ///
  /// 导出时各段各自按变体序号轮流取（见 [materialFor]）：总变体数只由画面
  /// 替换决定，配乐不做乘法——一段选 4 首，6 条变体就是 A/B/C/D/A/B。
  final List<BgmMaterial> materials;

  /// 预览播的是哪一首（[materials] 的下标）。预览只能放一个，
  /// 而导出会把备选都用上
  final int previewIndex;

  final BgmFit fit;

  /// 这一段配乐压到原始音量的几成（0~1）。
  ///
  /// **每段独立**：用户在不同段铺不同的曲子，有的本来就响、有的很闷，
  /// 一个全局值必然有一段不合适。
  final double volume;

  /// 默认压到四分之一——垫乐盖过台词是最常见的翻车方式，而这条片子的
  /// 主体是口播
  static const double defaultVolume = 0.25;

  /// 这一段是从老存档读来的、下标其实是**镜头**下标，还没换算成单元。
  /// 只在 [BgmPlan.migrateShotsToUnits] 之前为真
  final bool legacyShotRange;

  const BgmSegment({
    required this.startUnit,
    required this.endUnit,
    required this.materials,
    required this.fit,
    this.previewIndex = 0,
    this.volume = defaultVolume,
    this.legacyShotRange = false,
  });

  /// 第 [variantIndex] 条变体该用哪一首。轮流，用完一轮回到头
  BgmMaterial materialFor(int variantIndex) =>
      materials[variantIndex % materials.length];

  /// 预览播的那一首。下标越界时夹回第一个——方案是存在盘上的，
  /// 用户删掉几首备选之后下标可能就指不到了
  BgmMaterial get previewMaterial =>
      materials[previewIndex.clamp(0, materials.length - 1)];

  /// 夹回 0~1。构造函数是 const 的（很多地方直接 `const BgmSegment(...)`），
  /// 夹取只能放在入口：来自界面的滑块、来自存档的脏数据。
  static double clampVolume(double v) => v < 0
      ? 0
      : v > 1
          ? 1
          : v;

  bool covers(int unitIndex) => unitIndex >= startUnit && unitIndex <= endUnit;

  BgmSegment copyWith(
          {int? startUnit,
          int? endUnit,
          double? volume,
          List<BgmMaterial>? materials,
          int? previewIndex}) =>
      BgmSegment(
        startUnit: startUnit ?? this.startUnit,
        endUnit: endUnit ?? this.endUnit,
        materials: materials ?? this.materials,
        previewIndex: previewIndex ?? this.previewIndex,
        fit: fit,
        volume: volume ?? this.volume,
      );

  /// 两段的备选是不是同一组（顺序也要一样——轮流的次序有意义）
  bool sameAlternatives(BgmSegment other) {
    if (materials.length != other.materials.length) return false;
    for (var i = 0; i < materials.length; i++) {
      if (materials[i].id != other.materials[i].id) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'startUnit': startUnit,
        'endUnit': endUnit,
        'materials': [for (final m in materials) m.toJson()],
        'previewIndex': previewIndex,
        'fit': fit.name,
        'volume': volume,
      };

  /// 老存档用的是镜头下标（`startShot`/`endShot`）。这里照读，
  /// 由 [BgmPlan.migrateShotsToUnits] 换算成单元下标——直接丢掉的话，
  /// 用户已经选好的配乐会凭空消失
  static BgmSegment? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final legacy = raw['startUnit'] == null;
    final start = raw[legacy ? 'startShot' : 'startUnit'];
    final end = raw[legacy ? 'endShot' : 'endUnit'];
    if (start is! int || end is! int || end < start) return null;
    // 老存档一段只存一首曲子（`material`），新的是一组备选（`materials`）
    final list = raw['materials'];
    final materials = <BgmMaterial>[
      if (list is List)
        for (final item in list) ?BgmMaterial.tryFromJson(item)
      else
        ?BgmMaterial.tryFromJson(raw['material']),
    ];
    if (materials.isEmpty) return null;
    final fit = BgmFit.values.firstWhereOrNull((f) => f.name == raw['fit']);
    final volume = raw['volume'];
    return BgmSegment(
      startUnit: start,
      endUnit: end,
      materials: List.unmodifiable(materials),
      previewIndex:
          raw['previewIndex'] is int ? raw['previewIndex'] as int : 0,
      legacyShotRange: legacy,
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

  /// 这个台词语义单元归哪一段管；没有配乐时返回 null
  BgmSegment? segmentAt(int unitIndex) =>
      segments.firstWhereOrNull((s) => s.covers(unitIndex));

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

  /// 把 [material] 铺到 [startUnit]..[endUnit] 上。
  ///
  /// [rangeMs] 是这几个单元的实际总时长，用来判断裁还是循环——调用方
  /// 拿得到 units，这里不重复算一遍。
  BgmPlan assign({
    required int startUnit,
    required int endUnit,
    required List<BgmMaterial> materials,
    required int rangeMs,
    double volume = BgmSegment.defaultVolume,
    int previewIndex = 0,
  }) {
    // 一首都没选等于没铺这一段
    if (materials.isEmpty) return this;
    // 用户可能从右往左拖
    final from = startUnit <= endUnit ? startUnit : endUnit;
    final to = startUnit <= endUnit ? endUnit : startUnit;

    final next = <BgmSegment>[];
    for (final old in segments) {
      // 完全被压住：整段让出去
      if (old.startUnit >= from && old.endUnit <= to) continue;
      // 完全不相干：原样保留
      if (old.endUnit < from || old.startUnit > to) {
        next.add(old);
        continue;
      }
      // 部分重叠：左右各留下不重叠的那截（新段落在中间时会劈成两半）
      if (old.startUnit < from) {
        next.add(old.copyWith(endUnit: from - 1));
      }
      if (old.endUnit > to) {
        next.add(old.copyWith(startUnit: to + 1));
      }
    }
    final preview =
        materials[previewIndex.clamp(0, materials.length - 1)];
    next.add(BgmSegment(
      startUnit: from,
      endUnit: to,
      materials: List.unmodifiable(materials),
      previewIndex: previewIndex.clamp(0, materials.length - 1),
      // 「裁还是循环」按预览那一首算——时间线上显示的就是它
      fit: fitFor(materialDurationMs: preview.durationMs, rangeMs: rangeMs),
      volume: BgmSegment.clampVolume(volume),
    ));
    next.sort((a, b) => a.startUnit.compareTo(b.startUnit));
    // 刚放上去的这一段的音量是「最后设的」，合并时由它覆盖整段
    return _merged(next, winningVolume: BgmSegment.clampVolume(volume));
  }

  /// 把这个单元区间从所有配乐段里**抠掉**。
  ///
  /// 整体替换一个台词语义单元时用：那一段的画面、口播、配乐全部来自候选素材，
  /// 原来铺在它上面的配乐在这一段就不存在了。抠完可能是截断、劈成两段、
  /// 或整段消失。
  BgmPlan carveOutUnits(int fromUnit, int toUnit) {
    final from = fromUnit <= toUnit ? fromUnit : toUnit;
    final to = fromUnit <= toUnit ? toUnit : fromUnit;
    final next = <BgmSegment>[];
    for (final s in segments) {
      // 完全被盖住：整段没了
      if (s.startUnit >= from && s.endUnit <= to) continue;
      // 不相干：原样
      if (s.endUnit < from || s.startUnit > to) {
        next.add(s);
        continue;
      }
      // 左右各留下不重叠的那截；被抠的部分落在中间时劈成两段
      if (s.startUnit < from) next.add(s.copyWith(endUnit: from - 1));
      if (s.endUnit > to) next.add(s.copyWith(startUnit: to + 1));
    }
    next.sort((a, b) => a.startUnit.compareTo(b.startUnit));
    return BgmPlan(List.unmodifiable(next));
  }

  /// 一段配乐覆盖的单元对应到全片的哪一段时间；越界返回 null。
  ///
  /// 直接取单元的起止——不必再打平成镜头再换算，那是按镜头记区间时的做法。
  static (int, int)? unitRangeOf(List<SemanticUnit> units, BgmSegment segment) {
    if (units.isEmpty || segment.startUnit >= units.length) return null;
    final start = segment.startUnit.clamp(0, units.length - 1);
    final end = segment.endUnit.clamp(start, units.length - 1);
    return (units[start].startMs, units[end].endMs);
  }

  /// 把老存档里按**镜头**记的区间换算成单元区间。
  ///
  /// 跨到哪个单元就算到哪个单元——粒度变粗是这次改动的代价。镜头下标越界的
  /// 整段丢掉：留一段指向不存在单元的配乐，导出时才发现更糟。
  BgmPlan migrateShotsToUnits(List<SemanticUnit> units) {
    if (!segments.any((s) => s.legacyShotRange)) return this;
    final unitOfShot = <int>[];
    for (var u = 0; u < units.length; u++) {
      for (var i = 0; i < units[u].shots.length; i++) {
        unitOfShot.add(u);
      }
    }
    final next = <BgmSegment>[];
    for (final s in segments) {
      if (!s.legacyShotRange) {
        next.add(s);
        continue;
      }
      if (s.startUnit >= unitOfShot.length) {
        AppLog.warn('配乐「${s.previewMaterial.name}」的镜头区间已越界，迁移时丢弃');
        continue;
      }
      final from = unitOfShot[s.startUnit.clamp(0, unitOfShot.length - 1)];
      final to = unitOfShot[s.endUnit.clamp(0, unitOfShot.length - 1)];
      next.add(BgmSegment(
        startUnit: from,
        endUnit: to,
        materials: s.materials,
        previewIndex: s.previewIndex,
        fit: s.fit,
        volume: s.volume,
      ));
    }
    next.sort((a, b) => a.startUnit.compareTo(b.startUnit));
    return _merged(next);
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
      // 合并的条件是「备选列表完全相同」——顺序也算，轮流的次序有意义
      if (last != null &&
          last.sameAlternatives(s) &&
          last.endUnit + 1 == s.startUnit) {
        final volume = winningVolume ?? last.volume;
        if (last.volume != volume || s.volume != volume) changedVolume = true;
        out[out.length - 1] =
            last.copyWith(endUnit: s.endUnit, volume: volume);
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

  /// 只改某一段的音量，不换曲子。[startUnit] 用来认段；找不到就原样返回。
  BgmPlan withVolume({required int startUnit, required double volume}) =>
      BgmPlan(List.unmodifiable([
        for (final s in segments)
          if (s.startUnit == startUnit)
            s.copyWith(volume: BgmSegment.clampVolume(volume))
          else
            s,
      ]));

  /// 移除覆盖 [unitIndex] 的那一段；没有就原样返回
  BgmPlan removeAt(int unitIndex) {
    final target = segmentAt(unitIndex);
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
    parsed.sort((a, b) => a.startUnit.compareTo(b.startUnit));
    return BgmPlan(List.unmodifiable(parsed));
  }
}

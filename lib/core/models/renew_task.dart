import 'package:collection/collection.dart';
import '../analysis/providers.dart';
import '../log/app_log.dart';
import '../replacement/replacement_plan.dart';
import 'tag_group_ref.dart';
import 'video_info.dart';
import 'semantic_unit.dart';

/// 任务状态：分析中 / 编辑中 / 已导出
///
/// 曾经有 awaitingCut（待切分确认）与 picking（选材中）两个状态，对应
/// 「先确认切分、再进入替换选材」两个页面。两个页面合并成一个工作台后，
/// 这两个状态之间已没有任何行为差异——切分与选材在同一个页面里交替进行，
/// 再分成两个状态只会让任务卡显示一个用户无法据以行动的假区分。
/// 旧记录里的这两个名字由 [parseStatus] 兜底落到 [editing]。
enum RenewTaskStatus { analyzing, editing, exported }

/// 翻新任务实体（不可变）
class RenewTask {
  final String id;
  final String name;
  final String sourcePath;
  final String? miaoaVideoId;
  final VideoInfo? videoInfo;
  final String? coverPath;
  final RenewTaskStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<SemanticUnit>? units;
  final List<AsrSentence>? asrSentences;

  /// 台词语义单元打标所用的 miaoa 标签组（受控词表的来源）。
  ///
  /// 可以选多个：一个单元本来就该同时有几个维度的标签，只能选一个组等于
  /// 只能打一个维度。多个组的标签合并成一份受控词表。空表示该层不打标。
  final List<TagGroupRef> unitTagGroups;

  /// 视觉镜头打标所用的 miaoa 标签组（同样可多选）；空表示该层不打标
  final List<TagGroupRef> shotTagGroups;

  /// 兼容读法：只关心「有没有选」或「第一个是哪个」的地方继续用它
  TagGroupRef? get unitTagGroup =>
      unitTagGroups.isEmpty ? null : unitTagGroups.first;
  TagGroupRef? get shotTagGroup =>
      shotTagGroups.isEmpty ? null : shotTagGroups.first;

  /// 最近一次分析失败的原因摘要（已按长度截断）；为 null 表示未失败或已重试清除
  final String? analysisError;

  /// 阶段②「替换选材」的方案，按 [units] 的下标一一对齐；
  /// null 表示这条任务还没进过阶段②（旧任务读出来就是 null）。
  ///
  /// 长度未必与 [units] 相等：切分被改动后单元数会变，读取方（阶段②页面）
  /// 负责按当前单元数补位/截断，模型层不擅自纠正——擅自补位会把「用户到底
  /// 选过没有」这个事实抹掉。
  final List<UnitReplacement>? replacements;

  RenewTask({
    required this.id,
    required this.name,
    required this.sourcePath,
    this.miaoaVideoId,
    this.videoInfo,
    this.coverPath,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.units,
    this.asrSentences,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    this.analysisError,
    List<UnitReplacement>? replacements,
  })  : unitTagGroups = List.unmodifiable(unitTagGroups),
        shotTagGroups = List.unmodifiable(shotTagGroups),
        replacements =
            replacements == null ? null : List.unmodifiable(replacements);

  /// 标签组列表的宽松解析：先认新的数组字段，没有再退回旧的单个字段。
  ///
  /// 单条畸形只跳过它——为一个坏条目丢掉整条任务，用户看到的是「任务不见了」
  /// （本项目踩过这个坑）。
  static List<TagGroupRef> parseTagGroups(Object? list, Object? legacySingle) {
    if (list is List) {
      return List.unmodifiable([
        for (final e in list) ?TagGroupRef.tryFromJson(e),
      ]);
    }
    final single = TagGroupRef.tryFromJson(legacySingle);
    return single == null ? const [] : List.unmodifiable([single]);
  }

  static bool _sameGroups(List<TagGroupRef> a, List<TagGroupRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// [clearAnalysisError] 为 true 时显式清空 analysisError（重试分析时使用）；
  /// 其余可空字段沿用 units/asrSentences 的简单覆盖模式（不支持单独清空）。
  /// 技术债备注：清空可空字段目前是 per-field 布尔标志（每加一个需要清空的
  /// 字段就多一个 `clearXxx` 参数），若后续 videoInfo/coverPath 等字段也需要
  /// 支持清空，应收敛为统一的 sentinel 方案（例如用一个私有 `_unset` 哨兵对象
  /// 区分「未传参」与「显式传 null」），而不是继续堆叠布尔参数。
  RenewTask copyWith({
    String? id,
    String? name,
    String? sourcePath,
    String? miaoaVideoId,
    VideoInfo? videoInfo,
    String? coverPath,
    RenewTaskStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<SemanticUnit>? units,
    List<AsrSentence>? asrSentences,
    List<TagGroupRef>? unitTagGroups,
    List<TagGroupRef>? shotTagGroups,
    String? analysisError,
    bool clearAnalysisError = false,
    List<UnitReplacement>? replacements,
  }) =>
      RenewTask(
        id: id ?? this.id,
        name: name ?? this.name,
        sourcePath: sourcePath ?? this.sourcePath,
        miaoaVideoId: miaoaVideoId ?? this.miaoaVideoId,
        videoInfo: videoInfo ?? this.videoInfo,
        coverPath: coverPath ?? this.coverPath,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        units: units ?? this.units,
        asrSentences: asrSentences ?? this.asrSentences,
        unitTagGroups: unitTagGroups ?? this.unitTagGroups,
        shotTagGroups: shotTagGroups ?? this.shotTagGroups,
        analysisError:
            clearAnalysisError ? null : (analysisError ?? this.analysisError),
        replacements: replacements ?? this.replacements,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourcePath': sourcePath,
        'miaoaVideoId': miaoaVideoId,
        'videoInfo': videoInfo?.toJson(),
        'coverPath': coverPath,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'units': units?.map((u) => u.toJson()).toList(),
        'asrSentences': asrSentences?.map((s) => s.toJson()).toList(),
        'unitTagGroups': [for (final g in unitTagGroups) g.toJson()],
        'shotTagGroups': [for (final g in shotTagGroups) g.toJson()],
        // 旧字段一并写：本项目按「打包好的 .app 发给同事」分发，新旧版本会
        // 并存，旧版本只认单个字段，不写它任务在旧版本上就成了「没选标签组」
        'unitTagGroup': unitTagGroup?.toJson(),
        'shotTagGroup': shotTagGroup?.toJson(),
        'analysisError': analysisError,
        'replacements': replacements?.map((r) => r.toJson()).toList(),
      };

  factory RenewTask.fromJson(Map<String, dynamic> json) => RenewTask(
        id: json['id'] as String,
        name: json['name'] as String,
        sourcePath: json['sourcePath'] as String,
        miaoaVideoId: json['miaoaVideoId'] as String?,
        videoInfo: json['videoInfo'] == null
            ? null
            : VideoInfo.fromJson(json['videoInfo'] as Map<String, dynamic>),
        coverPath: json['coverPath'] as String?,
        status: parseStatus(json['status']),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        units: (json['units'] as List<dynamic>?)
            ?.map((e) => SemanticUnit.fromJson(e as Map<String, dynamic>))
            .toList(),
        asrSentences: (json['asrSentences'] as List<dynamic>?)
            ?.map((e) => AsrSentence.fromJson(e as Map<String, dynamic>))
            .toList(),
        unitTagGroups: parseTagGroups(json['unitTagGroups'], json['unitTagGroup']),
        shotTagGroups: parseTagGroups(json['shotTagGroups'], json['shotTagGroup']),
        analysisError: json['analysisError'] as String?,
        replacements: parseReplacements(json['replacements']),
      );

  /// 替换方案的宽松解析：整体畸形按「没进过阶段②」（null）处理，
  /// 单条畸形降级为保留原片但**保留位置**——列表下标就是台词语义单元下标，
  /// 少一条会让后面所有单元的方案整体错位到别的单元上。
  static List<UnitReplacement>? parseReplacements(Object? raw) {
    if (raw == null) return null;
    if (raw is! List) {
      AppLog.warn('任务替换方案字段不是数组（${raw.runtimeType}），按未选材处理');
      return null;
    }
    return List.unmodifiable([
      for (final entry in raw)
        UnitReplacement.tryFromJson(entry) ?? UnitReplacement.keepOriginal(),
    ]);
  }

  /// 未知/缺失状态一律回退到 [fallbackStatus]，绝不抛异常。
  ///
  /// 抛异常的后果是整条任务在 findAll 里被跳过——用户看到的是「我的任务不见
  /// 了」。未知值通常来自更新版本写入的后续状态（如导出中），回退到只读回看
  /// 的「选材中」最保守：既能看到任务、又不会误导用户去改已流转的数据。
  static RenewTaskStatus parseStatus(Object? raw) {
    final name = raw is String ? raw : null;
    if (name == null) return fallbackStatus;
    final matched =
        RenewTaskStatus.values.firstWhereOrNull((s) => s.name == name);
    if (matched != null) return matched;
    AppLog.warn('任务状态「$name」无法识别，按 ${fallbackStatus.name} 处理');
    return fallbackStatus;
  }

  static const fallbackStatus = RenewTaskStatus.editing;

  @override
  bool operator ==(Object other) =>
      other is RenewTask &&
      other.id == id &&
      other.name == name &&
      other.sourcePath == sourcePath &&
      other.miaoaVideoId == miaoaVideoId &&
      other.videoInfo == videoInfo &&
      other.coverPath == coverPath &&
      other.status == status &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      _sameGroups(other.unitTagGroups, unitTagGroups) &&
      _sameGroups(other.shotTagGroups, shotTagGroups) &&
      other.analysisError == analysisError &&
      const DeepCollectionEquality().equals(other.units, units) &&
      const DeepCollectionEquality().equals(other.asrSentences, asrSentences) &&
      const DeepCollectionEquality().equals(other.replacements, replacements);

  @override
  int get hashCode => Object.hash(
      id,
      name,
      sourcePath,
      miaoaVideoId,
      videoInfo,
      coverPath,
      status,
      createdAt,
      updatedAt,
      Object.hashAll(unitTagGroups),
      Object.hashAll(shotTagGroups),
      analysisError,
      units == null ? null : Object.hashAll(units!),
      asrSentences == null ? null : Object.hashAll(asrSentences!),
      replacements == null ? null : Object.hashAll(replacements!));
}

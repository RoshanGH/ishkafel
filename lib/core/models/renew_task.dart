import 'package:collection/collection.dart';
import '../analysis/providers.dart';
import '../log/app_log.dart';
import '../replacement/replacement_plan.dart';
import 'tag_group_ref.dart';
import 'video_info.dart';
import 'semantic_unit.dart';

/// 任务状态：分析中 / 待切分确认 / 选材中 / 已导出
enum RenewTaskStatus { analyzing, awaitingCut, picking, exported }

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

  /// 台词语义单元打标所用的 miaoa 标签组（受控词表的来源）；
  /// null 表示新建任务时未选择，该层不打标
  final TagGroupRef? unitTagGroup;

  /// 视觉镜头打标所用的 miaoa 标签组；null 表示未选择，该层不打标
  final TagGroupRef? shotTagGroup;

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
    this.unitTagGroup,
    this.shotTagGroup,
    this.analysisError,
    List<UnitReplacement>? replacements,
  }) : replacements =
            replacements == null ? null : List.unmodifiable(replacements);

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
    TagGroupRef? unitTagGroup,
    TagGroupRef? shotTagGroup,
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
        unitTagGroup: unitTagGroup ?? this.unitTagGroup,
        shotTagGroup: shotTagGroup ?? this.shotTagGroup,
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
        unitTagGroup: TagGroupRef.tryFromJson(json['unitTagGroup']),
        shotTagGroup: TagGroupRef.tryFromJson(json['shotTagGroup']),
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

  static const fallbackStatus = RenewTaskStatus.picking;

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
      other.unitTagGroup == unitTagGroup &&
      other.shotTagGroup == shotTagGroup &&
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
      unitTagGroup,
      shotTagGroup,
      analysisError,
      units == null ? null : Object.hashAll(units!),
      asrSentences == null ? null : Object.hashAll(asrSentences!),
      replacements == null ? null : Object.hashAll(replacements!));
}

import 'package:collection/collection.dart';
import '../analysis/providers.dart';
import '../log/app_log.dart';
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

  /// 最近一次分析失败的原因摘要（已按长度截断）；为 null 表示未失败或已重试清除
  final String? analysisError;

  const RenewTask({
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
    this.analysisError,
  });

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
    String? analysisError,
    bool clearAnalysisError = false,
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
        analysisError:
            clearAnalysisError ? null : (analysisError ?? this.analysisError),
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
        'analysisError': analysisError,
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
        analysisError: json['analysisError'] as String?,
      );

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
      other.analysisError == analysisError &&
      const DeepCollectionEquality().equals(other.units, units) &&
      const DeepCollectionEquality().equals(other.asrSentences, asrSentences);

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
      analysisError,
      units == null ? null : Object.hashAll(units!),
      asrSentences == null ? null : Object.hashAll(asrSentences!));
}

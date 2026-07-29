import 'package:collection/collection.dart';
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
  });

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
        status: RenewTaskStatus.values.byName(json['status'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        units: (json['units'] as List<dynamic>?)
            ?.map((e) => SemanticUnit.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

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
      const DeepCollectionEquality().equals(other.units, units);

  @override
  int get hashCode => Object.hash(id, name, sourcePath, miaoaVideoId, videoInfo,
      coverPath, status, createdAt, updatedAt, units == null ? null : Object.hashAll(units!));
}

import 'package:flutter/foundation.dart';

import '../log/app_log.dart';

/// 已经挑中的素材，**落到盘上的那一份**。
///
/// 为什么要落地而不是每次现拉：勾选状态原本只画在候选卡上，而候选卡只有
/// 当前这一页的检索结果。翻一页、换个检索方式、换个项目组、重开 app——
/// 选过的那几条就都不在结果里了，界面上一个勾都看不见。用户原话：
/// 「我没有看到我选了那 3 个，我不知道是不是我那 3 个」。
///
/// 落地的是**信息**，不是视频本体：
/// - 名字/台词/画面描述/时长：几百字节，随任务一起存，重开就有；
/// - 首帧图：下载成本地文件（[thumbPath]）。素材库给的是签名地址，
///   一天就过期，存 URL 等于存一张迟早打不开的图；
/// - 视频本体不预下载——一个单元可以挑好几条、一条几十兆，而真正要用它
///   是在预览合成和导出的时候，那两处本来就按 id 现取。
@immutable
class PickedMaterial {
  final int id;
  final String name;

  /// 这条素材原本在说什么
  final String voiceover;

  /// 画面描述（没有台词时退回它）
  final String sceneDescription;

  /// 首帧图在本地的路径；没下下来时为 null（托盘照样显示，只是没有图）
  final String? thumbPath;

  /// 探测到的时长；探不出来时为 null——不要用 0 冒充
  final int? durationMs;

  const PickedMaterial({
    required this.id,
    required this.name,
    this.voiceover = '',
    this.sceneDescription = '',
    this.thumbPath,
    this.durationMs,
  });

  /// 托盘上显示什么：台词 → 画面描述 → 素材名。三样都空时由调用方兜底
  String get label => voiceover.isNotEmpty
      ? voiceover
      : (sceneDescription.isNotEmpty ? sceneDescription : name);

  PickedMaterial withThumb(String? path) => PickedMaterial(
        id: id,
        name: name,
        voiceover: voiceover,
        sceneDescription: sceneDescription,
        thumbPath: path,
        durationMs: durationMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (voiceover.isNotEmpty) 'voiceover': voiceover,
        if (sceneDescription.isNotEmpty) 'sceneDescription': sceneDescription,
        if (thumbPath != null) 'thumbPath': thumbPath,
        if (durationMs != null) 'durationMs': durationMs,
      };

  /// 宽松解析：畸形的那一条跳过，不牵连整份任务——任务读不出来的代价是
  /// 「我的任务不见了」，比少一张缩略图严重得多
  static PickedMaterial? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! int) {
      AppLog.warn('已选素材缺少 id，跳过这一条');
      return null;
    }
    return PickedMaterial(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '素材 #$id',
      voiceover: raw['voiceover'] is String ? raw['voiceover'] as String : '',
      sceneDescription: raw['sceneDescription'] is String
          ? raw['sceneDescription'] as String
          : '',
      thumbPath: raw['thumbPath'] is String ? raw['thumbPath'] as String : null,
      durationMs: raw['durationMs'] is int ? raw['durationMs'] as int : null,
    );
  }

  static List<PickedMaterial> parseList(Object? raw) {
    if (raw is! List) return const [];
    return List.unmodifiable([
      for (final item in raw) ?tryFromJson(item),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is PickedMaterial &&
      other.id == id &&
      other.name == name &&
      other.voiceover == voiceover &&
      other.sceneDescription == sceneDescription &&
      other.thumbPath == thumbPath &&
      other.durationMs == durationMs;

  @override
  int get hashCode =>
      Object.hash(id, name, voiceover, sceneDescription, thumbPath, durationMs);

  @override
  String toString() => 'PickedMaterial($id, $name)';
}

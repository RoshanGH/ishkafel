import 'package:meta/meta.dart';

/// 导出规格：出多大、多清楚。
///
/// 参考剪映，但**刻意只给必要的那几项**：
/// - 不给 4K。素材库里都是 1080 竖版，上采样只让文件大一倍、画质一点不涨
/// - 不给自定义码率数字。用户不知道该填多少，填错了只会得到一条更差的片子；
///   画质三档已经覆盖实际需求
/// - 不给 mov。投放平台一律吃 mp4
///
/// 帧率**固定 30**：切片长度是按帧算的（见 [ExportCommands.frameCount]），
/// 改帧率会牵动整条时长链路。30fps 是竖屏投放的既定标准，真需要别的再说——
/// 这一条是明说的取舍，不是漏掉了。
@immutable
class ExportSpec {
  final int width;
  final int height;

  /// x264 的 CRF：**越小越清楚、文件越大**。18 视觉无损，23 是常规
  final int crf;

  const ExportSpec({
    required this.width,
    required this.height,
    required this.crf,
  });

  /// 1080×1920 · 高画质。翻新任务与空白任务的缺省
  static const standard = ExportSpec(width: 1080, height: 1920, crf: 20);

  /// 给界面用的几档分辨率
  static const resolutions = <({String label, int width, int height})>[
    (label: '1080×1920（推荐）', width: 1080, height: 1920),
    (label: '720×1280（更小）', width: 720, height: 1280),
  ];

  /// 给界面用的几档画质。文案说的是**用户能感知的东西**，不是 CRF 数字
  static const qualities = <({String label, String note, int crf})>[
    (label: '标准', note: '文件最小，适合快速过一遍', crf: 23),
    (label: '高（推荐）', note: '投放用这一档', crf: 20),
    (label: '最高', note: '几乎无损，文件明显更大', crf: 18),
  ];

  ExportSpec copyWith({int? width, int? height, int? crf}) => ExportSpec(
        width: width ?? this.width,
        height: height ?? this.height,
        crf: crf ?? this.crf,
      );

  String get resolutionLabel => '$width×$height';

  String get qualityLabel =>
      qualities.firstWhere((q) => q.crf == crf, orElse: () => qualities[1]).label;

  Map<String, dynamic> toJson() =>
      {'width': width, 'height': height, 'crf': crf};

  static ExportSpec fromJson(Object? raw) {
    if (raw is! Map) return standard;
    return ExportSpec(
      width: raw['width'] as int? ?? standard.width,
      height: raw['height'] as int? ?? standard.height,
      crf: raw['crf'] as int? ?? standard.crf,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExportSpec &&
      other.width == width &&
      other.height == height &&
      other.crf == crf;

  @override
  int get hashCode => Object.hash(width, height, crf);

  @override
  String toString() => '$resolutionLabel · $qualityLabel';
}

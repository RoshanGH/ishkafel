import 'package:meta/meta.dart';

/// 码率档位。剪映给的是「推荐 / 更高 / 更低 / 自定义」，这里一一对上。
///
/// 前三档落到 x264 的 CRF（**恒定质量**）而不是固定码率：同样一档，
/// 画面简单的段自动少给码率，复杂的段多给——比固定码率省一半体积而看不出
/// 区别。自定义那一档才是真的定死码率，因为用户点它就是想要一个确定的值。
enum BitrateMode { lower, recommended, higher, custom }

/// 编码。H.264 到处都能播；HEVC 同画质文件小三成，但**软编慢得多**，
/// 而且老设备与部分平台不认
enum VideoCodec { h264, hevc }

enum ContainerFormat { mp4, mov }

/// 导出规格。选项对齐剪映专业版的导出面板。
///
/// 竖屏 9:16 是本产品的主要工作对象，所以「1080P」指的是 1080×1920
/// （短边 1080），不是横屏的 1920×1080。
@immutable
class ExportSpec {
  /// 短边（480 / 720 / 1080 / 1440 / 2160）
  final int shortSide;

  /// 24 / 25 / 30 / 50 / 60
  final int fps;

  final BitrateMode bitrate;

  /// [BitrateMode.custom] 时的码率，单位 kbps。剪映的上限是 240000
  final int customKbps;

  final VideoCodec codec;
  final ContainerFormat format;

  const ExportSpec({
    this.shortSide = 1080,
    this.fps = 30,
    this.bitrate = BitrateMode.recommended,
    this.customKbps = 20000,
    this.codec = VideoCodec.h264,
    this.format = ContainerFormat.mp4,
  });

  static const standard = ExportSpec();

  /// 剪映的档位。竖屏下短边就是宽
  static const resolutions = <({String label, int shortSide})>[
    (label: '480P', shortSide: 480),
    (label: '720P', shortSide: 720),
    (label: '1080P', shortSide: 1080),
    (label: '2K', shortSide: 1440),
    (label: '4K', shortSide: 2160),
  ];

  static const frameRates = <int>[24, 25, 30, 50, 60];

  static const maxCustomKbps = 240000;

  int get width => shortSide;

  /// 9:16。偶数是必须的——yuv420p 要求宽高都能被 2 整除
  int get height {
    final raw = (shortSide * 16 / 9).round();
    return raw.isEven ? raw : raw + 1;
  }

  String get resolutionLabel => resolutions
      .firstWhere((r) => r.shortSide == shortSide,
          orElse: () => (label: '${shortSide}P', shortSide: shortSide))
      .label;

  String get bitrateLabel => switch (bitrate) {
        BitrateMode.lower => '更低',
        BitrateMode.recommended => '推荐',
        BitrateMode.higher => '更高',
        BitrateMode.custom => '自定义 $customKbps kbps',
      };

  /// 前三档用 CRF；数字越小越清楚
  int get crf => switch (bitrate) {
        BitrateMode.lower => 26,
        BitrateMode.recommended => 20,
        BitrateMode.higher => 17,
        // 自定义走定码率，这个值用不到
        BitrateMode.custom => 20,
      };

  String get encoderName =>
      codec == VideoCodec.hevc ? 'libx265' : 'libx264';

  String get fileExtension => format == ContainerFormat.mov ? 'mov' : 'mp4';

  /// HEVC 在 mp4 里要标 hvc1，否则 macOS 的播放器与相册认不出来
  List<String> get tagArgs =>
      codec == VideoCodec.hevc ? const ['-tag:v', 'hvc1'] : const [];

  /// 编码参数。自定义码率时走定码率（含 maxrate/bufsize，否则「自定义」
  /// 只是个平均值，峰值段照样糊）
  List<String> get encodeArgs => [
        '-c:v', encoderName,
        '-preset', codec == VideoCodec.hevc ? 'medium' : 'veryfast',
        if (bitrate == BitrateMode.custom) ...[
          '-b:v', '${customKbps}k',
          '-maxrate', '${customKbps}k',
          '-bufsize', '${customKbps * 2}k',
        ] else ...[
          '-crf', '$crf',
        ],
        ...tagArgs,
      ];

  ExportSpec copyWith({
    int? shortSide,
    int? fps,
    BitrateMode? bitrate,
    int? customKbps,
    VideoCodec? codec,
    ContainerFormat? format,
  }) =>
      ExportSpec(
        shortSide: shortSide ?? this.shortSide,
        fps: fps ?? this.fps,
        bitrate: bitrate ?? this.bitrate,
        customKbps: customKbps ?? this.customKbps,
        codec: codec ?? this.codec,
        format: format ?? this.format,
      );

  /// 缓存指纹。**规格必须进指纹**：同一段在 1080 和 720 下是两份不同的产物，
  /// 不区分的话第二次导出会直接命中第一次的缓存，用户拿到的还是旧规格
  String get fingerprint => '${width}x$height-$fps-${bitrate.name}'
      '${bitrate == BitrateMode.custom ? customKbps : crf}-${codec.name}';

  Map<String, dynamic> toJson() => {
        'shortSide': shortSide,
        'fps': fps,
        'bitrate': bitrate.name,
        'customKbps': customKbps,
        'codec': codec.name,
        'format': format.name,
      };

  static ExportSpec fromJson(Object? raw) {
    if (raw is! Map) return standard;
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.where((v) => v.name == name).firstOrNull ?? fallback;
    return ExportSpec(
      shortSide: raw['shortSide'] as int? ?? standard.shortSide,
      fps: raw['fps'] as int? ?? standard.fps,
      bitrate: pick(BitrateMode.values, raw['bitrate'], BitrateMode.recommended),
      customKbps: raw['customKbps'] as int? ?? standard.customKbps,
      codec: pick(VideoCodec.values, raw['codec'], VideoCodec.h264),
      format: pick(ContainerFormat.values, raw['format'], ContainerFormat.mp4),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExportSpec &&
      other.shortSide == shortSide &&
      other.fps == fps &&
      other.bitrate == bitrate &&
      other.customKbps == customKbps &&
      other.codec == codec &&
      other.format == format;

  @override
  int get hashCode =>
      Object.hash(shortSide, fps, bitrate, customKbps, codec, format);

  @override
  String toString() =>
      '$resolutionLabel · ${fps}fps · $bitrateLabel · ${codec.name}';
}

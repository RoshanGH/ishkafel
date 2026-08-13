import 'package:meta/meta.dart';

/// 码率档位。剪映给的是「推荐 / 更高 / 更低 / 自定义」，这里一一对上。
///
/// 前三档不是玄学：**按分辨率 × 帧率算出具体的码率数字**（见
/// [ExportSpec.kbps]），选项上直接写着多少 Mbps，编码就按这个数字来。
/// 界面显示的和实际编出来的是同一个值。
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

  /// 这一档在当前分辨率、帧率下的**具体码率**（kbps）。
  ///
  /// 按每像素每帧的比特数（bpp）算：推荐档 0.19 bpp——1080×1920@30 正好
  /// 落在 12 Mbps（业内对 1080P 竖版的常见建议值），分辨率或帧率一变，
  /// 数字跟着变。更低 0.12、更高 0.28。取整到千位，界面上是整数 Mbps
  int get kbps {
    if (bitrate == BitrateMode.custom) return customKbps;
    final bpp = switch (bitrate) {
      BitrateMode.lower => 0.12,
      BitrateMode.recommended => 0.19,
      BitrateMode.higher => 0.28,
      BitrateMode.custom => 0.19, // 不可达
    };
    final raw = width * height * fps * bpp / 1000;
    return (raw / 1000).round().clamp(1, maxCustomKbps ~/ 1000) * 1000;
  }

  /// 某一档在当前分辨率、帧率下的码率（给界面把数字写在选项上）
  int kbpsOf(BitrateMode mode) => copyWith(bitrate: mode).kbps;

  String get bitrateLabel => switch (bitrate) {
        BitrateMode.lower => '更低（${kbps ~/ 1000} Mbps）',
        BitrateMode.recommended => '推荐（${kbps ~/ 1000} Mbps）',
        BitrateMode.higher => '更高（${kbps ~/ 1000} Mbps）',
        BitrateMode.custom => '自定义（$customKbps kbps）',
      };

  String get encoderName =>
      codec == VideoCodec.hevc ? 'libx265' : 'libx264';

  String get fileExtension => format == ContainerFormat.mov ? 'mov' : 'mp4';

  /// HEVC 在 mp4 里要标 hvc1，否则 macOS 的播放器与相册认不出来
  List<String> get tagArgs =>
      codec == VideoCodec.hevc ? const ['-tag:v', 'hvc1'] : const [];

  /// 编码参数。**界面上写多少就编多少**：一律按 [kbps] 定码率，
  /// 带 maxrate/bufsize——只给 -b:v 的话那是个平均值，峰值段照样糊
  List<String> get encodeArgs => [
        '-c:v', encoderName,
        '-preset', codec == VideoCodec.hevc ? 'medium' : 'veryfast',
        '-b:v', '${kbps}k',
        '-maxrate', '${kbps}k',
        '-bufsize', '${kbps * 2}k',
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
  String get fingerprint =>
      '${width}x$height-$fps-$kbps-${codec.name}';

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

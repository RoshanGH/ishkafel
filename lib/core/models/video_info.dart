import '../time/rational.dart';
/// 视频元信息（不可变）
class VideoInfo {
  final int width;
  final int height;
  final Duration duration;
  final double fps;

  /// 帧率的**精确**形式。ffprobe 给的是 `30000/1001` 这种分数，转成 double
  /// 之后 29.97 和 30 在很多地方就分不开了（`round(1000/fps)` 对两者都是
  /// 33ms）。存原始分数，需要精确判等、进缓存指纹时用它。
  /// 老存档里只有 double，那时按「离哪个标准帧率最近」认回来。
  final Rational? _fpsExact;

  /// 帧率的精确形式。没有原始分数时从 [fps] 认回来——29.97 会认回
  /// 30000/1001，而不是 29970/1000
  Rational get fpsExact => _fpsExact ?? Rational.fromDouble(fps);
  final int fileSizeBytes;

  const VideoInfo({
    Rational? fpsExact,

    required this.width,
    required this.height,
    required this.duration,
    required this.fps,
    required this.fileSizeBytes,
  })  :
        // 对外叫 fpsExact，对内是私有字段——外面拿到的永远是 getter，
        // 没存原始分数时从 double 认回来
        // ignore: prefer_initializing_formals
        _fpsExact = fpsExact;

  bool get isPortrait => height > width;

  /// 从 ffprobe -print_format json 的输出解析；无视频流时抛 [FormatException]
  factory VideoInfo.fromFfprobeJson(Map<String, dynamic> json) {
    final streams = (json['streams'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final video = streams.firstWhere(
      (s) => s['codec_type'] == 'video',
      orElse: () => throw const FormatException('ffprobe 输出中没有视频流'),
    );
    final format = (json['format'] as Map<String, dynamic>? ?? const {});
    final durationSec = double.tryParse('${format['duration']}') ?? 0;
    // r_frame_rate 非法（部分容器确实会报 0/0、N/A）时回退 avg_frame_rate；
    // 两者都拿不到就抛错，绝不返回 0 帧率——下游按帧计算会得到 Infinity/NaN。
    final fps = parseFrameRate(video['r_frame_rate']) ??
        parseFrameRate(video['avg_frame_rate']);
    if (fps == null) {
      throw const FormatException(
          'ffprobe 输出中缺少可用帧率（r_frame_rate / avg_frame_rate 均非法）');
    }
    return VideoInfo(
      fpsExact: Rational.tryParse('${video['r_frame_rate'] ?? ''}') ??
          Rational.tryParse('${video['avg_frame_rate'] ?? ''}') ??
          Rational.fromDouble(fps),
      width: video['width'] as int,
      height: video['height'] as int,
      duration: Duration(milliseconds: (durationSec * 1000).round()),
      fps: fps,
      fileSizeBytes: int.tryParse('${format['size']}') ?? 0,
    );
  }

  /// 解析 ffprobe 的帧率字段：支持 `30/1`、`30000/1001` 分数与 `29.97` 小数。
  ///
  /// `0/0`、`N/A`、空串、null、非正数一律视为非法并返回 null，由调用方决定
  /// 回退或拒绝；历史实现在这些情况下返回 0，导致审片台 `1000/0` 得到
  /// Infinity、`totalFrames ~/ 0` 抛整除零异常而红屏。
  static double? parseFrameRate(Object? raw) {
    if (raw == null) return null;
    final text = '$raw'.trim();
    if (text.isEmpty) return null;
    final parts = text.split('/');
    final fps = switch (parts.length) {
      1 => double.tryParse(parts[0]),
      2 => _divide(double.tryParse(parts[0]), double.tryParse(parts[1])),
      _ => null,
    };
    if (fps == null || !fps.isFinite || fps <= 0) return null;
    return fps;
  }

  static double? _divide(double? numerator, double? denominator) =>
      (numerator == null || denominator == null || denominator == 0)
          ? null
          : numerator / denominator;

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'durationMs': duration.inMilliseconds,
        'fps': fps,
        // 精确帧率也存下来：老存档只有 double，读回来只能按「离哪个标准帧率
        // 最近」猜；新存档存原始分数，29.97 和 30 永远分得开
        'fpsExact': fpsExact.toString(),
        'fileSizeBytes': fileSizeBytes,
      };

  factory VideoInfo.fromJson(Map<String, dynamic> json) => VideoInfo(
        width: json['width'] as int,
        height: json['height'] as int,
        duration: Duration(milliseconds: json['durationMs'] as int),
        fps: (json['fps'] as num).toDouble(),
        fpsExact: Rational.tryParse('${json['fpsExact'] ?? ''}') ??
            Rational.fromDouble((json['fps'] as num).toDouble()),
        fileSizeBytes: json['fileSizeBytes'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is VideoInfo &&
      other.width == width &&
      other.height == height &&
      other.duration == duration &&
      other.fps == fps &&
      other.fileSizeBytes == fileSizeBytes;

  @override
  int get hashCode => Object.hash(width, height, duration, fps, fileSizeBytes);
}

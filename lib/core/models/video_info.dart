/// 视频元信息（不可变）
class VideoInfo {
  final int width;
  final int height;
  final Duration duration;
  final double fps;
  final int fileSizeBytes;

  const VideoInfo({
    required this.width,
    required this.height,
    required this.duration,
    required this.fps,
    required this.fileSizeBytes,
  });

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
    return VideoInfo(
      width: video['width'] as int,
      height: video['height'] as int,
      duration: Duration(milliseconds: (durationSec * 1000).round()),
      fps: _parseFps('${video['r_frame_rate']}'),
      fileSizeBytes: int.tryParse('${format['size']}') ?? 0,
    );
  }

  static double _parseFps(String raw) {
    final parts = raw.split('/');
    if (parts.length == 2) {
      final den = double.tryParse(parts[1]) ?? 1;
      final num = double.tryParse(parts[0]) ?? 0;
      return den == 0 ? 0 : num / den;
    }
    return double.tryParse(raw) ?? 0;
  }

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'durationMs': duration.inMilliseconds,
        'fps': fps,
        'fileSizeBytes': fileSizeBytes,
      };

  factory VideoInfo.fromJson(Map<String, dynamic> json) => VideoInfo(
        width: json['width'] as int,
        height: json['height'] as int,
        duration: Duration(milliseconds: json['durationMs'] as int),
        fps: (json['fps'] as num).toDouble(),
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

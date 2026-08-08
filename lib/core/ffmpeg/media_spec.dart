import 'package:flutter/foundation.dart';

/// 一条片子的**解码规格**：换段时播放器要不要重建解码器，就看这几项。
///
/// 真机实测（这是本项目最难查的一个问题）：原片是 HEVC **Main 10**
/// （`yuv420p10le`），素材库给的候选是 HEVC **Main**（`yuv420p`），其余
/// 编码/分辨率/帧率/音频全都一样。就这一处不同，播放器在换段那一刻必须
/// 重建解码器——画面停约 100ms 再跳过去，用户感知为「替换点有顿挫」。
///
/// 排查时先后否掉的几个假设，记在这里免得后人重走：
/// - 不是色深渲染：硬解走 videotoolbox，输出格式在 GPU 侧本来就是统一的；
/// - 不是丢帧：`frame-drop-count` 等三个计数器全程 0；
/// - 不是读取慢：把预读缓冲开到 20 秒 / 400MB，毫无改善；
/// - 不是音画纠偏：整段播放里一次纠偏都没触发；
/// - 也不是「双播放器交替」能解决的：待命中的播放器从 `play()` 到画面动
///   起来同样要 60~100ms。
@immutable
class MediaSpec {
  final String codec;
  final String profile;
  final String pixelFormat;
  final int width;
  final int height;

  /// 帧率写成 `30/1` 这种原始形式——`29.97` 和 `30000/1001` 是同一回事，
  /// 按字符串比会误判成不同
  final String frameRate;

  const MediaSpec({
    required this.codec,
    required this.profile,
    required this.pixelFormat,
    required this.width,
    required this.height,
    required this.frameRate,
  });

  /// 解码器要不要重建，只看这几项——码率、时长、音频参数都不影响
  bool sameAs(MediaSpec other) =>
      codec == other.codec &&
      profile == other.profile &&
      pixelFormat == other.pixelFormat &&
      width == other.width &&
      height == other.height &&
      _fps(frameRate) == _fps(other.frameRate);

  /// 帧率的数值形式。`30000/1001` 这种分数写法也认，读不出来时是 0
  double get fps => _fps(frameRate);

  static double _fps(String raw) {
    final parts = raw.split('/');
    if (parts.length != 2) return double.tryParse(raw) ?? 0;
    final num = double.tryParse(parts[0]) ?? 0;
    final den = double.tryParse(parts[1]) ?? 1;
    if (den == 0) return 0;
    // 保留两位：29.97 与 30000/1001 是同一回事
    return double.parse((num / den).toStringAsFixed(2));
  }

  /// ffprobe 的 `default=nw=1` 输出（`key=value` 一行一个）
  static MediaSpec? tryParse(String output) {
    final map = <String, String>{};
    for (final line in output.split('\n')) {
      final at = line.indexOf('=');
      if (at <= 0) continue;
      map[line.substring(0, at).trim()] = line.substring(at + 1).trim();
    }
    final width = int.tryParse(map['width'] ?? '');
    final height = int.tryParse(map['height'] ?? '');
    if (width == null || height == null) return null;
    return MediaSpec(
      codec: map['codec_name'] ?? '',
      profile: map['profile'] ?? '',
      pixelFormat: map['pix_fmt'] ?? '',
      width: width,
      height: height,
      frameRate: map['r_frame_rate'] ?? '',
    );
  }

  /// 读这几项的 ffprobe 参数
  static List<String> probeArgs(String path) => [
        '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries',
        'stream=codec_name,profile,pix_fmt,width,height,r_frame_rate',
        '-of', 'default=nw=1',
        path,
      ];

  @override
  String toString() =>
      '$codec/$profile $pixelFormat ${width}x$height @$frameRate';
}

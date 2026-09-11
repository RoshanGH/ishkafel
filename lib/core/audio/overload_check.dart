/// 一段声音的电平，以及「叠加有没有把它推过头」的判据。
///
/// 背景：成片的各层声音是**相加**的（见 `ExportCommands._sumTwo`）——
/// 用户定的规则，和剪映的时序轴一致：各层保持自己的音量，谁也不因为多了
/// 一层而变小。代价是叠出来可能过载。
///
/// 处置方式也是用户定的：**不偷偷压音量躲过去**（那又变成软件背着人做判断），
/// 而是如实报出来是哪一段，他自己决定调哪一层。
library;

class AudioLevels {
  /// 峰值（dBFS）。0 表示已经贴到满刻度
  final double maxDb;

  /// 贴在满刻度上的采样点数。ffmpeg 的 `histogram_0db`
  final int clippedSamples;

  const AudioLevels({required this.maxDb, required this.clippedSamples});

  /// 48kHz 立体声下，10 毫秒是多少个采样点。
  ///
  /// 阈值用「多久」而不是「多少个点」：几个点的削顶听不出来，真机上叠一层
  /// 素材原声只多了 7 个（2026-09-11）。报这种噪音只会让人学会无视警告
  static const int _audibleSamples = 48000 * 2 * 10 ~/ 1000;

  /// 解析 ffmpeg `volumedetect` 打在 stderr 上的那几行。量不到返回 null——
  /// **不许猜一个数出来**，猜出来的警告比不报更糟
  static AudioLevels? parse(String output) {
    final max = RegExp(r'max_volume:\s*(-?[0-9.]+) dB').firstMatch(output);
    if (max == null) return null;
    final clipped =
        RegExp(r'histogram_0db:\s*([0-9]+)').firstMatch(output);
    return AudioLevels(
      maxDb: double.parse(max.group(1)!),
      clippedSamples:
          clipped == null ? 0 : int.parse(clipped.group(1)!),
    );
  }

  /// 叠加**新添**了可听见的过载没有。
  ///
  /// 判据不能是「峰值到 0 dB」：原片母带本来就压到顶，真机上口播轨自己就有
  /// 四万多个采样点贴在 0 dB。那不是叠加造成的，报它等于每条片子都报
  static bool addedClipping({AudioLevels? base, AudioLevels? mixed}) {
    if (base == null || mixed == null) return false;
    return mixed.clippedSamples - base.clippedSamples >= _audibleSamples;
  }
}

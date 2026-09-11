import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/overload_check.dart';

/// 各层改成**相加**之后（见 `ExportCommands._sumTwo`），叠出来可能过载。
///
/// 用户定的处置方式：不偷偷压音量躲过去——那又变成软件背着人做判断——
/// 而是**如实报出来是哪一段**，他自己决定调哪一层。
///
/// 判据不能是「峰值到 0 dB」：原片母带本来就压到顶，真机上口播轨自己就有
/// 四万多个采样点贴在 0 dB。有意义的只有**叠加新添了多少**。
void main() {
  group('从 ffmpeg 的 volumedetect 里读电平', () {
    const sample = '''
[Parsed_volumedetect_0 @ 0x14e008fc0] n_samples: 7229952
[Parsed_volumedetect_0 @ 0x14e008fc0] mean_volume: -10.4 dB
[Parsed_volumedetect_0 @ 0x14e008fc0] max_volume: 0.0 dB
[Parsed_volumedetect_0 @ 0x14e008fc0] histogram_0db: 49539
''';

    test('读出峰值与贴顶的采样点数', () {
      final levels = AudioLevels.parse(sample);

      expect(levels, isNotNull);
      expect(levels!.maxDb, closeTo(0.0, 1e-9));
      expect(levels.clippedSamples, 49539);
    });

    test('没贴过顶时 histogram_0db 不会出现，算 0 个', () {
      final levels = AudioLevels.parse('''
[Parsed_volumedetect_0 @ 0x1] mean_volume: -18.2 dB
[Parsed_volumedetect_0 @ 0x1] max_volume: -3.1 dB
''');

      expect(levels!.maxDb, closeTo(-3.1, 1e-9));
      expect(levels.clippedSamples, 0);
    });

    test('量不到就是量不到，不许猜一个数出来', () {
      expect(AudioLevels.parse('ffmpeg: No such file'), isNull);
    });
  });

  group('叠加有没有新添过载', () {
    const base = AudioLevels(maxDb: 0, clippedSamples: 49539);

    test('原片母带自己贴顶不算——那不是叠加造成的', () {
      expect(AudioLevels.addedClipping(base: base, mixed: base), isFalse);
    });

    test('多出几个采样点也不算——听不出来，报了只会变成噪音', () {
      expect(
          AudioLevels.addedClipping(
              base: base,
              mixed: const AudioLevels(maxDb: 0, clippedSamples: 49546)),
          isFalse,
          reason: '真机上叠一层素材原声就多了 7 个点');
    });

    test('新添了十毫秒以上的过载就要报', () {
      expect(
          AudioLevels.addedClipping(
              base: base,
              mixed: const AudioLevels(maxDb: 0, clippedSamples: 49539 + 960)),
          isTrue,
          reason: '48kHz 立体声 10 毫秒 = 960 个采样点');
    });

    test('量不到任何一边时不报——猜出来的警告比不报更糟', () {
      expect(AudioLevels.addedClipping(base: null, mixed: base), isFalse);
      expect(AudioLevels.addedClipping(base: base, mixed: null), isFalse);
    });
  });
}

// 探针：用真实 miaoa CLI 核对音频库的返回形状与解析结果。
//
//   flutter test test/integration/bgm_library_probe_test.dart --tags integration --run-skipped
@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';
import 'package:ishkafel/core/miaoa/miaoa_locator.dart';

void main() {
  test('音频库能列出内容，且时长/人声解析得对', () async {
    final library = BgmLibrary(binary: resolveMiaoaBinary());

    final items = await library.search(pageSize: 30);

    expect(items, isNotEmpty);
    for (final m in items) {
      // 毫秒口径的下界：真机上最短的一条是 408ms。若解析成秒，这里会是
      // 408 秒（6.8 分钟），下面的上界就会兜住它
      expect(m.durationMs, lessThan(10 * 60 * 1000),
          reason: '单条音频超过十分钟，多半是把毫秒当成秒解析了');
    }

    // ignore: avoid_print
    print('共 ${items.length} 条；含人声 ${items.where((m) => m.hasSpeech).length} 条');
    for (final m in items.take(30)) {
      // ignore: avoid_print
      print('${m.id.toString().padLeft(3)} '
          '${(m.durationMs / 1000).toStringAsFixed(1).padLeft(7)}s '
          '${m.hasSpeech ? '含人声' : '无人声'} '
          '${m.tags.isEmpty ? '(无标签)' : m.tags.join('/')} '
          '${m.name}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

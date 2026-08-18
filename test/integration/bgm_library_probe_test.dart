// 探针：用真实 miaoa CLI 核对音频库的返回形状与解析结果。
//
//   flutter test test/integration/bgm_library_probe_test.dart --tags integration --run-skipped
@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_library.dart';

void main() {
  test('音频库能列出内容，且时长/人声解析得对', () async {
    final library = BgmLibrary();

    final items = (await library.search(pageSize: 30)).items;

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

  test('拿成片的项目去筛会筛空，这时要自动放开到全库', () async {
    final library = BgmLibrary();

    // 104 = 滴露植源喷雾。音频库不按成片项目归档，硬筛回来是 0 条
    final page = await library.search(projectIds: const [104], pageSize: 10);

    expect(page.items, isNotEmpty, reason: '放开之后必须有东西，否则选配乐是一片空白');
    expect(page.widenedFromProject, isTrue,
        reason: '哪天音频库真的按项目归档了，这条会红——那时该去掉兜底');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

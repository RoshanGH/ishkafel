import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **「原片时刻 → 成片时刻」这个方向已经删掉，不许复活。**
///
/// 它是一串真机故障的共同病灶（见
/// `docs/2026-09-08-成片时间轴重构-TRD.md`）：给一个原片时刻问它在成片哪儿，
/// 这个问题**本身没有唯一答案**——可能无人覆盖（手加的单元）、可能多人覆盖，
/// 而 `endMs` 是开区间，边界必然落到相邻那一段身上。列表顺序和原片顺序一致时
/// 恰好相等，所以平时看不出来；拖动调序是一等功能，一调就失效。
///
/// 同一个病灶发出过四个症状，每个都不报错、表现还各不一样：
/// 整格画不出来 / 点不中 / 双击播不了 / 末尾对不齐。
void main() {
  Iterable<File> dartFiles(String dir) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  test('lib 里不存在 toComposedMs', () {
    final offenders = [
      for (final f in dartFiles('lib'))
        if (RegExp(r'\btoComposedMs\s*\(').hasMatch(f.readAsStringSync()))
          f.path,
    ];

    expect(offenders, isEmpty,
        reason: '「原片 → 成片」这条路又回来了：\n${offenders.join('\n')}\n'
            '要「这一段在成片哪儿」，按列表下标问 startOf/durationOf/'
            'composedShotStart/composedShotEnd');
  });

  test('几何层不接受原片毫秒', () {
    final src =
        File('lib/features/workbench/timeline/timeline_geometry.dart')
            .readAsStringSync();

    expect(RegExp(r'double\s+msToPx\s*\(').hasMatch(src), isFalse,
        reason: 'msToPx(原片毫秒) 是那条病态路的入口，已删除');
  });

  test('位置只能按下标问——绘制、命中、视图里一处例外都没有', () {
    // 兜底也集中在 track_px.dart 一个文件里，别处一处都不许有
    const allowed = 'lib/features/workbench/timeline/track_px.dart';
    final offenders = <String>[];
    for (final f in dartFiles('lib')) {
      if (f.path == allowed) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r'msToPx\s*\(').allMatches(src)) {
        // 注释里提到名字不算
        final lineStart = src.lastIndexOf('\n', m.start) + 1;
        if (src.substring(lineStart, m.start).trimLeft().startsWith('///')) {
          continue;
        }
        offenders.add(f.path);
        break;
      }
    }

    expect(offenders, isEmpty,
        reason: '这些地方拿原片毫秒换算像素：\n${offenders.join('\n')}\n'
            '改成 unitPx(下标, units, geometry) / '
            'shotPx(单元下标, 镜头下标, units, geometry)');
  });

  test('双击播放传的是下标，不是毫秒', () {
    final src = File('lib/features/workbench/timeline/timeline_view.dart')
        .readAsStringSync();

    expect(src, contains('void Function(int unitIndex, int? shotIndex)?'),
        reason: '传毫秒的话上层还得换算一次，又会踩同一个坑');
  });

  test('换方案时的位置锚点是「单元下标 + 偏移 + 当时长度」，不绕原片时刻', () {
    final src =
        File('lib/core/playback/track_plan.dart').readAsStringSync();

    expect(src, contains('(int, int, int)? anchorAt('),
        reason: '锚在原片时刻上，垫黑场那种没有真实原片坐标的段必然错');
  });
}

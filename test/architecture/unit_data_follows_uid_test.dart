import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **挂在台词语义单元上的东西，一律按它自己的身份记。**
///
/// 产品负责人 2026-09-09：
///
/// > 这个台词语义单元应该有一个自己的编号，但不是 U1 U2 U3，因为它位置排序
/// > 是有可能会变的。它这个编号下的所有数据都是跟着这个编号走。
///
/// 半年里因为「按位置记」漏搬过三次，每次都是不报错、只有把片子导出来看一遍
/// 才发现：配音念错段落（09-07）、挑好的素材留在原来那一格（09-08）、
/// 手改字幕烧到别人的画面上（09-09）。
///
/// 现在四份都按身份记了。这条守卫盯的是**别再冒出第五种按位置记的**：
/// 存档里凡是「某个单元的什么」，键必须是 `unitUid`，不能是 `unitIndex`。
void main() {
  test('落盘的键里不许再出现 unitIndex', () {
    final offenders = <String>[];
    for (final path in [
      'lib/core/models/renew_task.dart',
      'lib/core/models/semantic_unit.dart',
      'lib/core/audio/voice_plan.dart',
      'lib/core/subtitle/subtitle_track.dart',
      'lib/core/replacement/replacement_plan.dart',
    ]) {
      final src = File(path).readAsStringSync();
      for (final line in src.split('\n')) {
        final code = line.trim();
        if (code.startsWith('//') || code.startsWith('///')) continue;
        // 只查**写出去**的那一侧：读老存档时认 unitIndex 是迁移，必须留着
        if (RegExp(r"'unitIndex':").hasMatch(code)) {
          offenders.add('$path: $code');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: '这些地方还在按位置往存档里写「哪个单元的什么」。'
            '人一挪单元它就指错人，而且不报错：\n${offenders.join('\n')}');
  });

  /// 配乐是**唯一**还按下标记的一份，而且是故意的：它记的不是「某个单元的
  /// 什么」，是**一段区间**——「这几段连着铺一首曲子」。区间天生就是位置的
  /// 概念，把两端换成身份不会让它变简单：所有的重叠切分、相邻合并、拉伸
  /// 都要在位置上算，只会来回换算两遍。
  ///
  /// 而且挪动确实会改变「这一段盖住谁」——那是要跟人说清楚的事
  /// （`remapBgmAfterMove` 会把被打断的段落报出来），不是搬一下就完的。
  ///
  /// 这条测试把这个例外钉住：只剩配乐一份，再多一份就得回来重新想。
  test('还按位置搬的只剩配乐一份', () {
    final remaps = <String>[];
    for (final path in [
      'lib/core/editing/unit_reorder.dart',
      'lib/core/editing/blank_unit_removal.dart',
    ]) {
      final src = File(path).readAsStringSync();
      for (final line in src.split('\n')) {
        final m = RegExp(r'^\w[\w<>, ]* (remap|shift)(\w+)(After\w+)\(')
            .firstMatch(line);
        if (m != null) remaps.add(m.group(2)!);
      }
    }

    expect(remaps.toSet(), {'Bgm'},
        reason: '除了配乐，别的都该按单元的身份记、一份都不用搬。'
            '这里多出来一个，说明有人又加了一份按位置记的数据：$remaps');
  });
}

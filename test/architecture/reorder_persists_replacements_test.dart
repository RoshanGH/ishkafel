import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **改了替换方案就必须落库——重排和删单元也不例外。**
///
/// 2026-09-08 真机：挪完单元、重开任务，挑给它的素材回到了原来那一格。
///
/// 页面上 `_replacements` 是内存里的一份，盘上那份在 `_task.replacements`。
/// 挑素材、剔除候选那几条路都是「setState 改内存 → copyWith 写进 _task →
/// savePickingPlan 落盘」三步一起做；唯独**重排**和**删单元**只做了第一步。
/// 于是内存里对、盘上还是旧的——下次打开就退回去了，而且不报任何错。
void main() {
  final src =
      File('lib/features/workbench/workbench_page.dart').readAsStringSync();

  /// 取某个方法的函数体
  String body(String signature) {
    final i = src.indexOf(signature);
    expect(i, greaterThan(0), reason: '找不到 $signature，方法改名了就更新这里');
    var depth = 0;
    var k = src.indexOf('{', i);
    final start = k;
    while (true) {
      if (src[k] == '{') depth++;
      if (src[k] == '}') {
        depth--;
        if (depth == 0) break;
      }
      k++;
    }
    return src.substring(start, k);
  }

  test('重排单元之后，替换方案写进任务并落盘', () {
    final code = body('Future<void> _reorderUnit(');

    expect(code, contains('savePickingPlan'),
        reason: '只改内存不落盘：重开任务时素材会退回挪动之前那一格');
    expect(code, contains('replacements:'),
        reason: '_task 里那份也要跟着改，否则任何读 _task.replacements 的地方'
            '拿到的都是旧映射');
  });

  test('删掉单元之后，同样要落盘', () {
    final code = body('Future<void> _deleteBlankUnit(');

    expect(code, contains('savePickingPlan'));
    expect(code, contains('replacements:'));
  });
}

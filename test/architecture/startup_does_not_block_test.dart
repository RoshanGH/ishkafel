import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **首屏前面不许排队干活。**
///
/// 2026-09-09 性能走查：启动时「清孤儿产物」挡在 `runApp` 前面 await——
/// 它要把全部任务读一遍、再扫一遍产物目录，盘上东西多时是好几百毫秒的
/// 纯 IO。人点了图标，只能对着 Dock 上跳动的图标等，什么都看不到。
///
/// 判据很简单：`runApp` 之前只留**首屏正确性真正依赖**的那几步。
/// 物料迁移是例外——它会改素材的落地位置，UI 读到路径之前必须做完。
void main() {
  test('清孤儿产物不挡首屏', () {
    final src = File('lib/main.dart').readAsStringSync();
    final beforeRunApp = src.substring(0, src.indexOf('runApp('));

    expect(beforeRunApp.contains('await _sweepOrphans'), isFalse,
        reason: '清孤儿是维护性的活，晚几秒开始不影响任何正在用的数据，'
            '不该让人对着 Dock 等它扫完');
    expect(src, contains('unawaited(_sweepOrphans'),
        reason: '挪到后台，但还是要跑——不跑的话盘上的垃圾永远清不掉');
  });

  test('物料迁移仍然挡在前面——它改的是素材的落地位置', () {
    final src = File('lib/main.dart').readAsStringSync();
    final beforeRunApp = src.substring(0, src.indexOf('runApp('));

    expect(beforeRunApp, contains('await migrateSharedMediaToTasks'),
        reason: '迁移没做完就开 UI，界面会拿着旧位置的路径去读文件');
  });
}

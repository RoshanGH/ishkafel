import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/ui_action.dart';

/// 可视模式得覆盖**最慢最贵的那几步**，不然它没什么用。
///
/// 此前解锁的唯一办法是让界面**退出**那个任务，而一退出就什么都看不见。
/// 于是识别台词、逐镜打标、逐句配音——几分钟、几十次识图加几十句 TTS，
/// 全程人对着一块不动的板子。验收 Agent 的原话：
///
/// > 最花时间的几步恰好不支持可视……可视模式真正动起来是从挑镜头才开始。
///
/// 现在改成界面把写锁让出来、自己转成只读跟随：Agent 改哪一行就滚到哪一行，
/// 数据当场刷出来。人要抢回去点「我来接手」。
void main() {
  test('有「让出写锁但留在页面」这个动作', () {
    expect(UiAction.parse('lock.yield'), UiAction.lockYield);
  });

  test('编导台真的接这个动作——它此前一个委派都接不了', () {
    final src =
        File('lib/features/director/director_page.dart').readAsStringSync();
    expect(src, contains('UiAction.lockYield'),
        reason: '脚本成片这条线在可视模式下一直是聋的');
    expect(src, contains('consumeAgentRequest'),
        reason: '没有接单通道，加了动作也没人应');
    expect(src, contains('_flushNow'),
        reason: '让位前要把没落盘的改动冲下去——让完这一页就写不进去了');
  });

  test('慢的那几步撞到界面占锁时会请它让位，而不是直接报错', () {
    // 识别台词 / 配音 / 导出都在这个文件里
    final run =
        File('lib/cli/commands/script_run_command.dart').readAsStringSync();
    expect(run, contains('acquireYieldingFromUi'),
        reason: 'extract 和 voice 正是最慢最贵的两步，'
            '它们撞锁就直接报错的话，人只能让界面退出去——那就看不见了');
    expect(run.contains('if (!lock.acquire('), isFalse,
        reason: '还留着不让位的老路，就会有一半命令照旧把人赶出页面');

    final apply =
        File('lib/cli/commands/script_apply_command.dart').readAsStringSync();
    expect(apply, contains('acquireYieldingFromUi'));
  });
}

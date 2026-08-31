import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一条可视动作办完了，就得放行下一条——**不能等这个 Future 走完**。
///
/// 建脚本成片任务那条路会 `await` 进编导台的路由，而那个 Future 要等
/// **人退出编导台**才返回。把互斥标志挂在 `whenComplete` 上，它就永远
/// 不放：`ui new-task` 之后每一条可视动作都被静默挡掉，Agent 只能等到
/// 超时，而界面明明开着、上一条命令刚刚还通过界面把任务建了出来。
///
/// 验收 Agent 撞的原样：建完任务紧接着跑 `ishkafel ui tasks`（那正是
/// 建任务回执里指定的下一步），连着两次白等 90 秒，exit 5。它的第一反应
/// 是「我的环境坏了」——因为界面就在眼前开着。
///
/// 同一个陷阱这个文件里踩过一次：撤场当初也压在后面，播报因此一直停在
/// 「正在新建任务」，那次的修法是把撤场提到 `await created` 之前。
void main() {
  test('回执发出就放行，不押在 whenComplete 上', () {
    final src =
        File('lib/features/tasks/task_list_page.dart').readAsStringSync();

    // reply 里必须自己把锁放掉
    final replyBody = src.substring(
        src.indexOf('void reply(bool ok, String message,'),
        src.indexOf('final action = UiAction.parse(req.kind);'));
    expect(replyBody, contains('_handlingAction = false'),
        reason: '回执都发出去了还占着互斥锁，后面每一条可视动作都会被静默挡掉');
  });

  test('那条会一直挂着的 await 还在——这条测试不是无的放矢', () {
    final src =
        File('lib/features/tasks/task_list_page.dart').readAsStringSync();
    expect(src, contains('await created'),
        reason: '如果这个 await 已经不在了，说明结构变了，'
            '回来重读这条测试的前提是否还成立');
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `apply plans` 两条路（直写 / 委派）**返回结构必须一致**。
///
/// 验收 Agent 撞到的原样：同一个任务、同一份方案、同一条烧着 5 条字的素材，
/// 直写返回带 `burnedText`，委派返回只有 `{ok, via, message, plans, units}`。
/// 检查**跑了**（`task --json` 里 framesSeen=3、burnedText 5 条都在），
/// 界面上**也报了**（播报条上一条橙色的警告），**只有 Agent 拿不到**。
///
/// 它原话：「不是『人能干的事 Agent 干不了』，是**人能看到的信息 Agent
/// 拿不到**。」而委派恰恰发生在界面开着、也就是人正在旁边看的时候——
/// 人扭头问「它刚才说啥了？有问题吗？」，Agent 答不上来。
///
/// 更麻烦的是它试了四种条件也没找出什么时候走哪条路：**同一条命令的返回
/// 结构在同样的表面条件下会变**。那样「拿到 burnedText 就换素材」这段逻辑
/// 根本没法写。
void main() {
  final source = File('lib/cli/commands/apply_command.dart').readAsStringSync();

  String bodyOf(String name) {
    final start = source.indexOf(RegExp('^\\w[^\n]* $name\\(', multiLine: true));
    expect(start, greaterThan(0), reason: '$name 的定义没找到，测试该更新了');
    final end = source.indexOf('\n}\n', start);
    return end < 0 ? source.substring(start) : source.substring(start, end);
  }

  test('两条路给的是同一份报告，不是各写一份', () {
    for (final name in ['_applyWithLock', '_applyPlansViaUi']) {
      expect(bodyOf(name), contains('planApplyReport'),
          reason: '$name 自己拼返回。两条路各拼一份的话迟早只有一份是全的'
              '——委派那份一度只有 {ok, via, message, plans, units}');
    }
  });

  test('那份报告里，会毁掉整片的两条都要有', () {
    final report = bodyOf('planApplyReport');
    for (final entry in {
      'burnedTextNotice': '素材画面上烧着字——成片两层字幕',
      'brandConflictNotice': '品牌错位——台词说的和画面里摆的对不上',
      'brandMismatchNotice': '候选一致但整条跑到别家去了',
      'trimUnavailableNotice': '量不到时长，倍速算不出来',
      "'materials'": 'Agent 靠它确认素材时长收到没有',
    }.entries) {
      expect(report, contains(entry.key),
          reason: '报告里少了 ${entry.key}（${entry.value}）');
    }
  });

  test('返回结构不许因为走哪条路而变——那样调用方没法写逻辑', () {
    // 委派那条路要能报出 plans：它一度只回 result.payload，
    // 而界面那头压根不知道有几条方案
    expect(bodyOf('_applyPlansViaUi'), contains('plans = validation.plans'),
        reason: '委派路径不解析方案的话，报告里的 plans 永远是空');
  });
}

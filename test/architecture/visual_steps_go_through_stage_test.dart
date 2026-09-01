import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **可视模式下的每一句播报都要经过 [AgentStage]。**
///
/// 裸调 `writeAgentPresence` 只写「我在干什么」这行字——不确认界面在哪、
/// 不把人带到现场、不等展示完。真机事故：脚本成片的配音一句句念
/// 「正在给第 10 句配音（10/20）」，而界面停在任务列表，二十句没有一格
/// 出现在屏幕上。播报没说谎，可视化却没发生。
///
/// 产品负责人的话：「它并不判断当前是否是它执行的那个页面，这样的话
/// 可视化的意义就没有了。」
///
/// 静默模式下也要写在场状态（人可能正开着这一页）——那条路走
/// `AgentStage.note`，不要各写各的。
void main() {
  test('CLI 里不许裸调 writeAgentPresence，一律走 AgentStage', () {
    final offenders = <String>[];
    for (final f in Directory('lib/cli')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // 舞台自己就是那个唯一的出口
      if (f.path.endsWith('agent_stage.dart')) continue;
      final src = f.readAsStringSync();
      if (src.contains('writeAgentPresence(')) offenders.add(f.path);
    }
    expect(offenders, isEmpty,
        reason: '这些地方绕开了舞台，播报会照念但界面不会跟过去：\n'
            '${offenders.join('\n')}\n'
            '可视用 stage.show/think/warn，长活儿用 heartbeat，'
            '静默兜底用 stage.note');
  });

  test('舞台每走一步都要确认界面在不在现场', () {
    final src = File('lib/cli/agent_stage.dart').readAsStringSync();
    expect(src, contains('readUiWhere'),
        reason: '不读「界面在哪」就只能靠猜：要么从不导航（可视化落空），'
            '要么每步都导航（页面反复销毁重建，画面弹回第一行）');
    // show 是「一步」的定义，它必须问；heartbeat 是高频回调，节流后也要问
    final show = src.substring(src.indexOf('Future<void> show('));
    expect(show.contains('_ensureOnStage'), isTrue);
  });

  test('可视模式有出口也要有入口：ui open 把界面叫得回来', () {
    final src = File('lib/cli/commands/ui_command.dart').readAsStringSync();
    expect(src, contains("'open'"),
        reason: '只有 ui tasks 把界面支开、没有命令把它叫回来的话，'
            'Agent 一旦支开就再也回不到现场');
  });
}

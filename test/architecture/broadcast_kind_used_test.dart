import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 播报分了三类（进度 / 判断 / 发现问题），但**分类本身没有价值——
/// 用起来才有**。加了 `warn()` 却没人调，等于只改了个枚举。
///
/// 这个项目在「加了能力却没接上」这件事上栽过：`pickedMaterials` 加好了
/// 但只有界面在写，于是取段在 Agent 提交的方案上完全失效，白做一轮。
void main() {
  test('发现「会毁掉整片」的问题时，真的用了 warning 那一类', () {
    final workbench =
        File('lib/features/workbench/workbench_page.dart').readAsStringSync();
    expect(workbench, contains('warnAndHold'),
        reason: '委派提交方案是**人在旁边看着**的那条路。烧字和品牌错位'
            '只有看图才发现得了，不当场说出来，人看到的就是「一切正常」');
  });

  test('三类都要有地方能发——只留进度那一类等于没分', () {
    final stage = File('lib/cli/agent_stage.dart').readAsStringSync();
    for (final entry in {
      'think': '判断类：「标签命中 5318 条太宽，改用画面描述再搜一轮」'
          '——人肯把花钱的活交给静默模式，靠的正是看懂过它怎么想',
      'warn': '发现问题类：人可能要当场喊停',
    }.entries) {
      expect(stage, contains('Future<void> ${entry.key}('),
          reason: 'AgentStage 少了 ${entry.key}()。${entry.value}');
    }
  });

  test('播报条要真的按类型上色，不是存了字段却画成一个样', () {
    final bar = File('lib/features/agent/agent_broadcast_bar.dart')
        .readAsStringSync();
    expect(bar, contains('BroadcastKind.warning'));
    expect(bar, contains('BroadcastKind.judgement'));
  });

  test('类型要一路传到底——中间断一环，界面永远只看到进度', () {
    for (final entry in {
      'lib/core/storage/agent_presence.dart': 'Agent 写的状态文件',
      'lib/features/agent/agent_stage_overlay.dart': '界面读状态、推进播报流',
      'lib/features/workbench/serve_broadcast.dart': '界面代 Agent 干活时',
    }.entries) {
      expect(File(entry.key).readAsStringSync(), contains('kind'),
          reason: '${entry.value}（${entry.key}）没带上类型');
    }
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/agent/visual_pace.dart';

/// 可视化的节奏必须**只有一份**。
///
/// 真机撞过：播报条要求每步停 500ms 才回执，编导台和工作台各自等 320ms
/// 就回了——谁先回执 Agent 就走下一步，于是播报条的轮询整步扑空。
/// 分步播报明明写进了盘上，界面上一条都没显示出来。
void main() {
  test('回执前的等待只在一个地方定', () {
    final offenders = <String>[];
    for (final dir in [
      'lib/features/director',
      'lib/features/workbench',
      'lib/features/agent',
    ]) {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        // 只管**回执前的等待**：别的延迟（素材轮询、预览防抖）与
        // 「让人看清这一步」无关，不该被这条规矩绑住
        final pattern = RegExp(
            r'delayed\(\s*const Duration\(milliseconds: (\d+)\)[\s\S]{0,400}?writeAgentAck');
        for (final m in pattern.allMatches(src)) {
          offenders.add('${f.path}: ${m.group(1)}ms');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: '这些地方自己定了「停多久才回执」，应该用 visualStepDwell：\n'
            '${offenders.join('\n')}');
  });

  test('轮询要比每步停留密得多，否则整步会被错过', () {
    expect(visualPollInterval.inMilliseconds * 2,
        lessThanOrEqualTo(visualStepDwell.inMilliseconds));
  });
}

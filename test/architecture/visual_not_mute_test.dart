import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `--visual` 是**给人看的**：软件弹出来、跳到那个任务、界面跟着 Agent 动。
///
/// 真机撞到过：`script shots` 的签名里收了 `visual`，从头到尾却没建过
/// `AgentStage`——于是软件既不拉起、界面也不跟。人开着别的任务时，
/// 看到的是「Agent 说在给第 4 行找镜头」而界面纹丝不动。
///
/// 参数收了不用比压根没有更糟：调用方以为自己开了可视，实际什么都没发生。
void main() {
  test('收了 --visual 的命令，必须真的上报在场状态', () {
    final offenders = <String>[];
    for (final f in Directory('lib/cli/commands')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      final takesVisual = RegExp(r'bool\??\s+visual').hasMatch(src);
      if (!takesVisual) continue;
      // 自己建 stage，或者把 visual 透传给别人去建，都算数
      final reports = src.contains('AgentStage(') ||
          RegExp(r'visual:\s*visual').hasMatch(src);
      if (!reports) offenders.add(f.uri.pathSegments.last);
    }

    expect(offenders, isEmpty,
        reason: '这些命令收了 --visual 却从不上报，可视模式对它们是哑的：'
            '${offenders.join('、')}');
  });
}

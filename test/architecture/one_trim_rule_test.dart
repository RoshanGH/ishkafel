import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「这条素材怎么放进坑位」**只能有一个算法**。
///
/// 三条路要用同一个答案：人在软件里**预览**看到的、导出的 **mp4**、
/// 写进**剪映工程**的。任何一条走偏，人就会发现「我看到的和导出来的不一样」，
/// 那比三条都错更难排查。
///
/// 真机上这个错犯过两次：改了导出没改剪映（同一条片子导 mp4 是 1.0 倍、
/// 拖进剪映三十几倍快进），改了导出没改预览（软件里看着是快进、导出来不是）。
void main() {
  test('算倍速和取段只能走 trimFor，不许现算', () {
    final offenders = <String>[];
    // 这几个文件是三条路的落点
    for (final path in [
      'lib/core/export/export_plan.dart',
      'lib/core/jianying/renew_jianying_plan.dart',
      'lib/features/workbench/speed_fitter.dart',
      'lib/cli/plan_submission.dart',
    ]) {
      final src = File(path).readAsStringSync();
      if (!src.contains('trimFor(')) {
        offenders.add('$path 没走 trimFor');
      }
      // 现写的除法就是在自己算倍速
      for (final line in src.split('\n')) {
        if (line.trimLeft().startsWith('//')) continue;
        if (RegExp(r'(total|materialMs|candidateMs)\s*/\s*slot').hasMatch(line)) {
          offenders.add('$path: ${line.trim()}');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: '这些地方自己算倍速，会和别的路走岔：\n${offenders.join('\n')}');
  });
}

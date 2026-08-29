import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// core 里的提示语是**界面和命令行共用**的，所以不能只说「点某个按钮」——
/// 命令行那头没有按钮可点。
///
/// 真机撞到过：导出被拦下时说「请先点『生成配音』」，而 Agent 只有命令行，
/// 那是一条走不通的路（手册明写这种时候要说出来让人补，但更好的是别给死路）。
///
/// 写法：要么两条路都给（「在工作台上点 X，或者跑 ishkafel Y」），
/// 要么说清这件事只能人来做（比如 miaoa 登录要跳浏览器）。
void main() {
  test('core 里让人「点按钮」的提示，要给出命令行的走法', () {
    final offenders = <String>[];
    for (final f in Directory('lib/core')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // 提示语常常跨行拼接，所以按**整条语句**看（到分号为止），
      // 不是按行——按行的话「点某按钮」和「或者跑某命令」会被拆开
      final src = f.readAsStringSync();
      for (final stmt in src.split(';')) {
        final body = stmt
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        if (!RegExp(r'点「[^」]+」').hasMatch(body)) continue;
        // 同一句里给了命令行走法就算数
        if (body.contains('ishkafel ') || body.contains('miaoa ')) continue;
        offenders.add('${f.path}: ${body.trim().split('\n').first}');
      }
    }

    expect(offenders, isEmpty,
        reason: '这些提示只给了界面的走法，命令行那头是死路：\n'
            '${offenders.join('\n')}');
  });
}

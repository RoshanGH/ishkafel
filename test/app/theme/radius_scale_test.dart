import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_spacing.dart';

/// **圆角只有四档加一个全圆，不许随手打数字。**
///
/// 2026-09-10 走查：全项目 64 处硬编码圆角，其中 15 处的值（2 / 3 / 9 /
/// 10 / 14）压根不在 4 / 6 / 8 / 12 这个阶梯上——2 和 3 肉眼分不出，
/// 9 和 8、10 和 12 也分不出，但它们让「这是同一种控件吗」变得说不清。
/// 跟当初把八种字号收敛成五级是同一件事。
void main() {
  test('阶梯本身是四档 + 全圆', () {
    expect(AppRadius.all, [4.0, 6.0, 8.0, 12.0, 999.0]);
  });

  test('没人再直接写数字圆角', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.contains('app/theme')) continue;
      final src = file.readAsStringSync();
      for (final m
          in RegExp(r'BorderRadius\.circular\((\d)').allMatches(src)) {
        final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
        offenders.add('${file.path}:$line');
      }
    }

    expect(offenders, isEmpty,
        reason: '这些地方直接写了数字圆角：\n${offenders.join('\n')}\n'
            '用 AppRadius.xs/sm/md/lg，全圆用 AppRadius.pill');
  });
}

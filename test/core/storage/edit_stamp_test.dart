import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/edit_stamp.dart';
import 'package:ishkafel/core/storage/task_log.dart';

void main() {
  test('key 按 uid 生成，删单元挪单元都不会漂', () {
    expect(stampKeyForUnit('u-abc'), 'u:u-abc');
    expect(stampKeyForShot('u-abc', 2), 'u:u-abc/s:2');
    // 不含任何单元下标
    expect(stampKeyForShot('u-abc', 2), isNot(contains('unit')));
  });

  test('来回一趟不掉东西', () {
    final at = DateTime.parse('2026-09-17T14:22:07.412Z');
    final s = EditStamp(by: ActorKind.human, at: at);
    final back = EditStamp.tryFromJson(s.toJson())!;
    expect(back.by, ActorKind.human);
    expect(back.at.toUtc(), at);
  });

  test('读不懂就当没有，不让一个坏戳废掉整条任务', () {
    expect(EditStamp.tryFromJson(null), isNull);
    expect(EditStamp.tryFromJson({'by': 'human'}), isNull); // 缺 at
    expect(EditStamp.tryFromJson({'at': '不是时间'}), isNull);
  });
}

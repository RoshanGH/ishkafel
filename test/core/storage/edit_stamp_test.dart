import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/edit_stamp.dart';
import 'package:ishkafel/core/storage/task_log.dart';

void main() {
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

  test('by 是垃圾值时不猜成某一方，整条戳按没有处理', () {
    // 跟 TaskLogEntry.tryFromJson 同一条规矩：猜一个归属就是把
    // 「人 / Agent / 不知道」这三态悄悄压成两态——Agent 看到「这是我自己
    // 定的」很可能直接覆盖掉人的东西，猜错代价太大
    expect(
        EditStamp.tryFromJson(
            {'by': 'nobody', 'at': '2026-09-17T14:22:07.412Z'}),
        isNull);
  });
}

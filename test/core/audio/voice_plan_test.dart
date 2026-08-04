import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';

const _warm = VoiceRef(id: 'zh_female_wanwanxiaohe_moon_bigtts', name: '湾湾小何');
const _man = VoiceRef(id: 'zh_male_yangguangqingnian_moon_bigtts', name: '阳光青年');

void main() {
  group('音色按台词语义单元分配', () {
    test('给几个单元指定同一个音色', () {
      final plan = VoicePlan.empty.assign([0, 2, 3], _warm);

      expect(plan.voiceOf(0)?.name, '湾湾小何');
      expect(plan.voiceOf(2)?.name, '湾湾小何');
      expect(plan.voiceOf(3)?.name, '湾湾小何');
      expect(plan.voiceOf(1), isNull, reason: '没指定的单元保持原声');
    });

    test('另一批单元可以用另一个音色', () {
      final plan =
          VoicePlan.empty.assign([0, 2], _warm).assign([1, 4], _man);

      expect(plan.voiceOf(0)?.name, '湾湾小何');
      expect(plan.voiceOf(1)?.name, '阳光青年');
      expect(plan.voiceOf(4)?.name, '阳光青年');
    });

    test('重复指定同一个单元时后一次覆盖前一次', () {
      final plan = VoicePlan.empty.assign([0], _warm).assign([0], _man);

      expect(plan.voiceOf(0)?.name, '阳光青年');
      expect(plan.assignments, hasLength(1),
          reason: '同一个单元留两条记录，导出时不知道该听谁的');
    });

    test('取消指定就回到原声', () {
      final plan = VoicePlan.empty.assign([0, 1], _warm).clear([0]);

      expect(plan.voiceOf(0), isNull);
      expect(plan.voiceOf(1)?.name, '湾湾小何');
    });

    test('取消一个没指定过的单元是空操作', () {
      expect(VoicePlan.empty.clear([3]).assignments, isEmpty);
    });
  });

  group('哪些单元要重新配音', () {
    test('列出所有被指定了音色的单元，按下标升序', () {
      final plan = VoicePlan.empty.assign([4, 1], _warm).assign([2], _man);

      expect(plan.assignedUnits, [1, 2, 4]);
    });

    test('一个都没指定时为空——整条片子用原声', () {
      expect(VoicePlan.empty.assignedUnits, isEmpty);
    });
  });

  group('落盘往返', () {
    test('存下来再读回来是同一份', () {
      final plan = VoicePlan.empty.assign([0, 2], _warm).assign([1], _man);

      final back = VoicePlan.fromJson(plan.toJson());

      expect(back.voiceOf(0)?.id, _warm.id);
      expect(back.voiceOf(1)?.name, '阳光青年');
      expect(back.assignedUnits, [0, 1, 2]);
    });

    test('畸形数据只丢那一条，不让整条任务读不出来', () {
      final back = VoicePlan.fromJson([
        {'unitIndex': 0, 'voice': {'id': 'a', 'name': '甲'}},
        {'unitIndex': 'bad'},
        'not a map',
        {'unitIndex': 5},
      ]);

      expect(back.assignedUnits, [0],
          reason: '一条配音记录畸形就让整条任务从列表消失，'
              '用户看到的是「我的任务不见了」');
    });
  });
}

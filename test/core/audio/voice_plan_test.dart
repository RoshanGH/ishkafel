import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';

const _warm = VoiceRef(id: 'zh_female_wanwanxiaohe_moon_bigtts', name: '湾湾小何');
const _man = VoiceRef(id: 'zh_male_yangguangqingnian_moon_bigtts', name: '阳光青年');

void main() {
  _equality();

  group('音色按台词语义单元分配', () {
    test('给几个单元指定同一个音色', () {
      final plan = VoicePlan.empty.assign(['u0', 'u2', 'u3'], _warm);

      expect(plan.voiceOf('u0')?.name, '湾湾小何');
      expect(plan.voiceOf('u2')?.name, '湾湾小何');
      expect(plan.voiceOf('u3')?.name, '湾湾小何');
      expect(plan.voiceOf('u1'), isNull, reason: '没指定的单元保持原声');
    });

    test('另一批单元可以用另一个音色', () {
      final plan =
          VoicePlan.empty.assign(['u0', 'u2'], _warm).assign(['u1', 'u4'], _man);

      expect(plan.voiceOf('u0')?.name, '湾湾小何');
      expect(plan.voiceOf('u1')?.name, '阳光青年');
      expect(plan.voiceOf('u4')?.name, '阳光青年');
    });

    test('重复指定同一个单元时后一次覆盖前一次', () {
      final plan = VoicePlan.empty.assign(['u0'], _warm).assign(['u0'], _man);

      expect(plan.voiceOf('u0')?.name, '阳光青年');
      expect(plan.assignments, hasLength(1),
          reason: '同一个单元留两条记录，导出时不知道该听谁的');
    });

    test('取消指定就回到原声', () {
      final plan = VoicePlan.empty.assign(['u0', 'u1'], _warm).clear(['u0']);

      expect(plan.voiceOf('u0'), isNull);
      expect(plan.voiceOf('u1')?.name, '湾湾小何');
    });

    test('取消一个没指定过的单元是空操作', () {
      expect(VoicePlan.empty.clear(['u3']).assignments, isEmpty);
    });
  });

  group('哪些单元要重新配音', () {
    test('列出所有被指定了音色的单元——按身份，不按下标', () {
      final plan =
          VoicePlan.empty.assign(['u4', 'u1'], _warm).assign(['u2'], _man);

      expect(plan.assignedUnits, {'u1', 'u2', 'u4'},
          reason: '按下标记的话，人挪一次单元，本该念 U3 的配音就跑到 U2 身上');
    });

    test('一个都没指定时为空——整条片子用原声', () {
      expect(VoicePlan.empty.assignedUnits, isEmpty);
    });
  });

  group('落盘往返', () {
    test('存下来再读回来是同一份', () {
      final plan = VoicePlan.empty.assign(['u0', 'u2'], _warm).assign(['u1'], _man);

      final back = VoicePlan.fromJson(plan.toJson());

      expect(back.voiceOf('u0')?.id, _warm.id);
      expect(back.voiceOf('u1')?.name, '阳光青年');
      expect(back.assignedUnits, {'u0', 'u1', 'u2'});
    });

    /// 老存档里配音按**单元下标**记。读的时候翻译成身份——翻译不了的
    /// （那个下标已经不存在）就丢掉，不能挂到别人身上
    test('老存档按下标记的，读出来翻译成身份', () {
      final back = VoicePlan.fromJson([
        {'unitIndex': 0, 'voice': {'id': 'a', 'name': '甲'}},
        {'unitIndex': 9, 'voice': {'id': 'b', 'name': '乙'}},
      ], uidAt: (i) => i == 0 ? 'uA' : null);

      expect(back.assignedUnits, {'uA'});
      expect(back.voiceOf('uA')?.id, 'a');
    });

    test('畸形数据只丢那一条，不让整条任务读不出来', () {
      final back = VoicePlan.fromJson([
        {'unitUid': 'u0', 'voice': {'id': 'a', 'name': '甲'}},
        {'unitUid': 'bad'},
        'not a map',
        {'unitUid': 'u5'},
      ]);

      expect(back.assignedUnits, {'u0'},
          reason: '一条配音记录畸形就让整条任务从列表消失，'
              '用户看到的是「我的任务不见了」');
    });
  });
}

/// 时间线的 shouldRepaint 靠值相等判断要不要重画
void _equality() {
  group('值相等', () {
    test('内容相同的两份方案相等', () {
      final a = VoicePlan.empty.assign(['u0', 'u2'], _warm);
      final b = VoicePlan.empty.assign(['u0', 'u2'], _warm);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('音色不同就不等', () {
      expect(VoicePlan.empty.assign(['u0'], _warm),
          isNot(VoicePlan.empty.assign(['u0'], _man)));
    });

    test('单元不同就不等', () {
      expect(VoicePlan.empty.assign(['u0'], _warm),
          isNot(VoicePlan.empty.assign(['u1'], _warm)));
    });

    test('空方案彼此相等——否则每帧都判定为变了，播放时整条时间线每秒重画 30 次',
        () {
      expect(VoicePlan.empty, const VoicePlan([]));
    });
  });
}

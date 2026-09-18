import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/edit_stamp.dart';
import 'package:ishkafel/core/storage/task_log.dart';

/// **「这一处是谁定的」必须在 `task --json` 里看得见。**
///
/// 产品负责人的原话是「如果你**发现**这个是人已经修改的」——「发现」要求
/// 看当前数据就能看见，而不是先去翻一遍日志再自己对下标。手册也照这句
/// 写着「`task --json` 里就有，不用先去翻日志」。
///
/// 戳写进去了却不报，是这个项目记过账的那一类漏：**查到的空看起来正好像
/// 「没问题」**——Agent 会把人手定的切分当成自己的前作，一把覆盖掉。
void main() {
  final human = EditStamp(by: ActorKind.human, at: DateTime.utc(2026, 9, 17, 10));
  final agent = EditStamp(by: ActorKind.agent, at: DateTime.utc(2026, 9, 17, 11));

  RenewTask task({EditStamp? unitStamp, EditStamp? shotStamp}) => RenewTask(
        id: 't1',
        name: '测试',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 17),
        updatedAt: DateTime.utc(2026, 9, 17),
        units: [
          SemanticUnit(
            index: 0,
            startMs: 0,
            endMs: 1000,
            transcript: 'U1',
            editedBy: unitStamp,
            shots: [Shot(startMs: 0, endMs: 1000, editedBy: shotStamp)],
          ),
        ],
      );

  Map<String, dynamic> unitOf(RenewTask t) =>
      (taskToJson(t)['units'] as List).first as Map<String, dynamic>;
  Map<String, dynamic> shotOf(RenewTask t) =>
      (unitOf(t)['shots'] as List).first as Map<String, dynamic>;

  test('单元上的戳要报出来，人还是 Agent、什么时候定的都要带', () {
    final reported = unitOf(task(unitStamp: human))['editedBy'];
    expect(reported, isA<Map>(),
        reason: '单元存了 editedBy 却不报——手册说 task --json 里就有');
    expect((reported as Map)['by'], 'human');
    expect(reported['at'], human.at.toIso8601String());
  });

  test('镜头上的戳也要报出来——人常常只改某一镜', () {
    final reported = shotOf(task(shotStamp: agent))['editedBy'];
    expect(reported, isA<Map>(),
        reason: '镜头存了 editedBy 却不报，「哪一镜是人定的」就此消失');
    expect((reported as Map)['by'], 'agent');
  });

  test('没人定过就整个键不出现——「不知道」不能压成「是我定的」', () {
    expect(unitOf(task()).containsKey('editedBy'), isFalse);
    expect(shotOf(task()).containsKey('editedBy'), isFalse);
  });

  test('两层各报各的：单元是人定的、这一镜是 Agent 定的', () {
    final t = task(unitStamp: human, shotStamp: agent);
    expect((unitOf(t)['editedBy'] as Map)['by'], 'human');
    expect((shotOf(t)['editedBy'] as Map)['by'], 'agent');
  });
}

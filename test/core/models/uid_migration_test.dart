import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/unit_uid.dart';

/// **老存档迁移：每一份数据仍然挂在同一个单元上。**
///
/// 单元有了自己的身份之后，挂在它下面的东西（配音、手改字幕……）改成按身份记。
/// 存量存档里那些还是按**下标**记的，读档时翻译一次。这一步只做一次，
/// 落盘之后就是新格式。
///
/// 翻译错了等于把人的方案打乱，而且不报错——所以这条线盯的是「迁移前后
/// 每一份数据仍然挂在同一个单元上」。
void main() {
  Map<String, dynamic> legacyTask() => {
        'id': 't1',
        'name': '老任务',
        'sourcePath': '/v/src.mp4',
        'status': 'ready',
        'createdAt': '2026-09-01T00:00:00.000',
        'updatedAt': '2026-09-01T00:00:00.000',
        // 老存档：单元没有 uid
        'units': [
          {
            'index': 0,
            'startMs': 0,
            'endMs': 1000,
            'transcript': '第一句',
            'shots': [
              {'startMs': 0, 'endMs': 500},
              {'startMs': 500, 'endMs': 1000},
            ],
          },
          {
            'index': 1,
            'startMs': 1000,
            'endMs': 2000,
            'transcript': '第二句',
            'shots': [
              {'startMs': 1000, 'endMs': 2000},
            ],
          },
        ],
        // 老存档：配音按 unitIndex
        'voices': [
          {
            'unitIndex': 1,
            'voice': {'id': 'v1', 'name': '阳光青年'},
          },
        ],
        // 老存档：字幕按 unit 下标
        'subtitleTrack': [
          {
            'unit': 0,
            'shot': 1,
            'lines': [
              {'startMs': 0, 'endMs': 500, 'text': '手改过的'},
            ],
          },
        ],
      };

  test('单元补发身份，而且互不相同', () {
    final task = RenewTask.fromJson(legacyTask());

    final units = task.units!;
    expect(units.every((u) => isUnitUid(u.uid)), isTrue);
    expect(units[0].uid, isNot(units[1].uid));
  });

  test('配音仍然挂在第二句上', () {
    final task = RenewTask.fromJson(legacyTask());

    expect(task.voices.assignedUnits, {task.units![1].uid},
        reason: '翻译错一格，本该念第二句的配音就跑到第一句身上');
    expect(task.voices.voiceOf(task.units![1].uid)?.name, '阳光青年');
  });

  test('手改字幕仍然挂在第一句的第二镜上', () {
    final task = RenewTask.fromJson(legacyTask());

    final slot = task.subtitleTrack.editedSlots.single;
    expect(slot.unitUid, task.units![0].uid);
    expect(slot.shotIndex, 1);
  });

  test('迁移完落盘再读回来，身份不变、挂靠关系不变', () {
    final once = RenewTask.fromJson(legacyTask());
    final twice = RenewTask.fromJson(
        jsonDecode(jsonEncode(once.toJson())) as Map<String, dynamic>);

    expect(twice.units!.map((u) => u.uid), once.units!.map((u) => u.uid),
        reason: '身份是永久的：每读一次换一个的话，挂在它下面的东西全会掉');
    expect(twice.voices.assignedUnits, once.voices.assignedUnits);
    expect(twice.subtitleTrack.editedSlots.single.unitUid,
        once.subtitleTrack.editedSlots.single.unitUid);
  });

  test('指向不存在的单元那条丢掉，不许挂到别人身上', () {
    final raw = legacyTask();
    (raw['voices'] as List).add({
      'unitIndex': 9,
      'voice': {'id': 'v2', 'name': '别人的'},
    });
    (raw['subtitleTrack'] as List).add({
      'unit': 9,
      'shot': 0,
      'lines': [
        {'startMs': 0, 'endMs': 1, 'text': '别人的'},
      ],
    });

    final task = RenewTask.fromJson(raw);

    expect(task.voices.assignments, hasLength(1));
    expect(task.subtitleTrack.editedSlots, hasLength(1));
  });

  test('新存档（已经有 uid）原样读回来，不重新发', () {
    final raw = legacyTask();
    (raw['units'] as List)[0]['uid'] = 'keep-me';
    (raw['units'] as List)[1]['uid'] = 'keep-me-too';

    final task = RenewTask.fromJson(raw);

    expect(task.units!.map((u) => u.uid), ['keep-me', 'keep-me-too']);
  });
}

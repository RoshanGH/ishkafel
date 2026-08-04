import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';

const _a = TagGroupRef(id: 1, name: '画面类型');
const _b = TagGroupRef(id: 2, name: '画面动作');
const _c = TagGroupRef(id: 3, name: '情绪氛围');

RenewTask _task({
  List<TagGroupRef> unit = const [],
  List<TagGroupRef> shot = const [],
}) =>
    RenewTask(
      id: 't1',
      name: '片',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.editing,
      createdAt: DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 1),
      unitTagGroups: unit,
      shotTagGroups: shot,
    );

void main() {
  _layerPrompt();

  group('两层各自可以选多个标签组', () {
    test('原样存取', () {
      final t = _task(unit: [_a], shot: [_a, _b, _c]);

      expect(t.unitTagGroups, [_a]);
      expect(t.shotTagGroups, [_a, _b, _c]);
    });

    test('往返 JSON 不丢', () {
      final t = _task(unit: [_a, _b], shot: [_c]);

      final back = RenewTask.fromJson(t.toJson());

      expect(back.unitTagGroups, [_a, _b]);
      expect(back.shotTagGroups, [_c]);
    });

    test('对外只读，外部拿到后改不动任务里的那份', () {
      final t = _task(shot: [_a]);

      expect(() => t.shotTagGroups.add(_b), throwsUnsupportedError);
    });
  });

  group('旧任务读得出来（少一个字段就整条消失，这个坑踩过）', () {
    test('旧的单个 unitTagGroup / shotTagGroup 被读成单元素列表', () {
      final legacy = {
        'id': 'old',
        'name': '旧任务',
        'sourcePath': '/v/old.mp4',
        'status': 'awaitingCut',
        'createdAt': '2026-07-01T00:00:00.000Z',
        'updatedAt': '2026-07-01T00:00:00.000Z',
        'unitTagGroup': {'id': 1, 'name': '画面类型'},
        'shotTagGroup': {'id': 2, 'name': '画面动作'},
      };

      final t = RenewTask.fromJson(legacy);

      expect(t.unitTagGroups, [_a]);
      expect(t.shotTagGroups, [_b]);
    });

    test('两个字段都没有时是空列表，不是 null，也不抛异常', () {
      final t = RenewTask.fromJson({
        'id': 'old',
        'name': '更旧的任务',
        'sourcePath': '/v/old.mp4',
        'status': 'analyzing',
        'createdAt': '2026-07-01T00:00:00.000Z',
        'updatedAt': '2026-07-01T00:00:00.000Z',
      });

      expect(t.unitTagGroups, isEmpty);
      expect(t.shotTagGroups, isEmpty);
    });

    test('新字段优先于旧字段（同时存在时以新的为准）', () {
      final t = RenewTask.fromJson({
        'id': 'x',
        'name': 'x',
        'sourcePath': '/v/x.mp4',
        'status': 'awaitingCut',
        'createdAt': '2026-07-01T00:00:00.000Z',
        'updatedAt': '2026-07-01T00:00:00.000Z',
        'unitTagGroup': {'id': 1, 'name': '画面类型'},
        'unitTagGroups': [
          {'id': 2, 'name': '画面动作'},
          {'id': 3, 'name': '情绪氛围'},
        ],
      });

      expect(t.unitTagGroups, [_b, _c]);
    });

    test('列表里混进畸形条目只跳过它，不丢掉整条任务', () {
      final t = RenewTask.fromJson({
        'id': 'x',
        'name': 'x',
        'sourcePath': '/v/x.mp4',
        'status': 'awaitingCut',
        'createdAt': '2026-07-01T00:00:00.000Z',
        'updatedAt': '2026-07-01T00:00:00.000Z',
        'shotTagGroups': [
          {'id': 1, 'name': '画面类型'},
          'not-an-object',
          {'name': '缺 id'},
        ],
      });

      expect(t.shotTagGroups, [_a]);
    });
  });

  group('写回时旧字段也一起写（装了旧版本的同事还能读）', () {
    test('多选时旧字段写第一个，不写 null', () {
      final json = _task(shot: [_a, _b]).toJson();

      expect(json['shotTagGroups'], hasLength(2));
      expect(json['shotTagGroup'], isNotNull,
          reason: '本项目按「打包好的 .app 发给同事」分发，新旧版本会并存。'
              '旧版本只认单个字段，不写它会让任务在旧版本上变成「没选标签组」');
      expect((json['shotTagGroup'] as Map)['id'], 1);
    });

    test('一个都没选时旧字段为 null', () {
      final json = _task().toJson();

      expect(json['shotTagGroups'], isEmpty);
      expect(json['shotTagGroup'], isNull);
    });
  });

  group('copyWith', () {
    test('能整组替换', () {
      final t = _task(shot: [_a]).copyWith(shotTagGroups: [_b, _c]);

      expect(t.shotTagGroups, [_b, _c]);
    });

    test('不传时保持原值', () {
      final t = _task(shot: [_a]).copyWith(name: '改名');

      expect(t.shotTagGroups, [_a]);
    });
  });
}

/// 打标约束一层一条（此前是一组一条）
void _layerPrompt() {
  group('打标约束按层存', () {
    test('两层各存各的，往返 JSON 不丢', () {
      final t = _task(unit: [_a], shot: [_b, _c]).copyWith(
        unitTagPrompt: '按话术意图判断',
        shotTagPrompt: '只判断具体位置或物体表面',
      );

      final back = RenewTask.fromJson(t.toJson());

      expect(back.unitTagPrompt, '按话术意图判断');
      expect(back.shotTagPrompt, '只判断具体位置或物体表面');
    });

    test('没写过就是空串，不是 null——界面上少一层判空', () {
      expect(RenewTask.fromJson(_task().toJson()).unitTagPrompt, '');
    });

    test('旧任务里按组存的约束，迁移成这一层的约束', () {
      final json = _task(unit: [_a], shot: [_b]).toJson()
        ..['unitTagPrompt'] = null
        ..['shotTagPrompt'] = null
        ..['unitTagGroups'] = [
          {'id': 1, 'name': '画面类型', 'prompt': '  '},
          {'id': 9, 'name': '另一个组', 'prompt': '按话术意图判断'},
        ];

      final back = RenewTask.fromJson(json);

      expect(back.unitTagPrompt, '按话术意图判断',
          reason: '用户写过的东西凭空消失，比字段改名难查得多');
      expect(back.shotTagPrompt, '', reason: '旧数据里没写就是没写');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/features/tasks/task_card_hint.dart';

SemanticUnit _unit(int i) => SemanticUnit(
      index: i,
      startMs: i * 1000,
      endMs: (i + 1) * 1000,
      transcript: '第 $i 句',
      shots: [Shot(startMs: i * 1000, endMs: (i + 1) * 1000)],
    );

RenewTask _task({
  required RenewTaskStatus status,
  int? unitCount,
  String? error,
}) =>
    RenewTask(
      id: 't',
      name: '片',
      sourcePath: '/v/a.mp4',
      status: status,
      createdAt: DateTime.utc(2026, 7, 31),
      updatedAt: DateTime.utc(2026, 7, 31),
      analysisError: error,
      units: unitCount == null
          ? null
          : [for (var i = 0; i < unitCount; i++) _unit(i)],
    );

void main() {
  group('卡片要告诉用户「接下来该干什么」', () {
    test('待切分确认：点进去确认切分', () {
      final hint = taskCardHint(
          _task(status: RenewTaskStatus.awaitingCut, unitCount: 12));

      expect(hint, contains('确认切分'));
      expect(hint, contains('12'), reason: '顺带交代规模，用户好判断要花多久');
    });

    test('选材中：去挑候选素材', () {
      final hint =
          taskCardHint(_task(status: RenewTaskStatus.picking, unitCount: 8));

      expect(hint, contains('选材'));
    });

    test('已导出：说清它已经走完流程', () {
      final hint = taskCardHint(_task(status: RenewTaskStatus.exported));

      expect(hint, isNotEmpty);
      expect(hint, isNot(contains('点击')),
          reason: '已导出的任务点进去只会被拒绝，不该再引导用户去点它');
    });

    test('分析中：明确说不用管它', () {
      final hint = taskCardHint(_task(status: RenewTaskStatus.analyzing));

      expect(hint, anyOf(contains('等'), contains('稍候'), contains('自动')));
    });
  });

  group('异常态的引导优先于常规引导', () {
    test('分析失败：引导去重试，而不是去确认切分', () {
      final hint = taskCardHint(_task(
          status: RenewTaskStatus.analyzing, error: '网络超时'));

      expect(hint, contains('重新分析'));
      expect(hint, isNot(contains('确认切分')));
    });

    test('源文件缺失：优先于一切，先让人把文件放回去', () {
      final hint = taskCardHint(
          _task(status: RenewTaskStatus.awaitingCut, unitCount: 12),
          sourceMissing: true);

      expect(hint, contains('文件'));
      expect(hint, isNot(contains('确认切分')),
          reason: '源文件不在，点进审片台只有黑屏；先解决前提再谈下一步');
    });
  });

  group('规模信息缺失时不编造', () {
    test('还没有切分结果时不写「共 0 个单元」', () {
      final hint =
          taskCardHint(_task(status: RenewTaskStatus.awaitingCut));

      expect(hint, isNot(contains('0 个')),
          reason: '「共 0 个台词语义单元」会被读成分析出来是空的');
    });
  });
}

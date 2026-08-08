import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/export_record.dart';
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
  List<ExportRecord> exports = const [],
}) =>
    RenewTask(
      id: 't',
      name: '片',
      sourcePath: '/v/a.mp4',
      status: status,
      createdAt: DateTime.utc(2026, 7, 31),
      updatedAt: DateTime.utc(2026, 7, 31),
      analysisError: error,
      exports: exports,
      units: unitCount == null
          ? null
          : [for (var i = 0; i < unitCount; i++) _unit(i)],
    );

void main() {
  group('卡片要告诉用户「接下来该干什么」', () {
    test('可编辑（常态）：点进工作台，切分与选材都在里面', () {
      final hint = taskCardHint(
          _task(status: RenewTaskStatus.ready, unitCount: 12));

      expect(hint, contains('工作台'));
      expect(hint, contains('12'), reason: '顺带交代规模，用户好判断要花多久');
      expect(hint, isNot(contains('确认切分')),
          reason: '「确认切分」这道闸门已经不存在，还写在卡片上就是在指路到一个'
              '找不到的按钮');
    });

    test('导出过的项目：报上次导了几条，并说明还能接着导', () {
      final hint = taskCardHint(_task(
        status: RenewTaskStatus.ready,
        exports: [
          ExportRecord(
              at: DateTime.utc(2026, 8, 8),
              total: 6,
              succeeded: 6,
              outputDir: '/out'),
        ],
      ));

      expect(hint, contains('8月8日'));
      expect(hint, contains('6 条'));
      expect(hint, contains('可继续换素材再导'),
          reason: '导过一次不代表这个项目结束了——原片还在，换一批素材还能再导');
    });

    test('有失败的那次要点出来，不能只报成功数', () {
      final hint = taskCardHint(_task(
        status: RenewTaskStatus.ready,
        exports: [
          ExportRecord(
              at: DateTime.utc(2026, 8, 8),
              total: 6,
              succeeded: 4,
              outputDir: '/out'),
        ],
      ));

      expect(hint, contains('2 条失败'));
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
          _task(status: RenewTaskStatus.ready, unitCount: 12),
          sourceMissing: true);

      expect(hint, contains('文件'));
      expect(hint, isNot(contains('确认切分')),
          reason: '源文件不在，点进审片台只有黑屏；先解决前提再谈下一步');
    });
  });

  group('规模信息缺失时不编造', () {
    test('还没有切分结果时不写「共 0 个单元」', () {
      final hint =
          taskCardHint(_task(status: RenewTaskStatus.ready));

      expect(hint, isNot(contains('0 个')),
          reason: '「共 0 个台词语义单元」会被读成分析出来是空的');
    });
  });
}

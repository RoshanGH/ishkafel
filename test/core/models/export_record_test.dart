import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/export_record.dart';
import 'package:ishkafel/core/models/renew_task.dart';

RenewTask _task({List<ExportRecord> exports = const []}) => RenewTask(
      id: 't1',
      name: '项目',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 1),
      exports: exports,
    );

void main() {
  group('导出记录随项目存盘', () {
    test('存进去再读出来，四项都在', () {
      final task = _task(exports: [
        ExportRecord(
            at: DateTime.utc(2026, 8, 8, 20, 15),
            total: 6,
            succeeded: 5,
            outputDir: '/Users/me/Movies/滴露'),
      ]);

      final back = RenewTask.fromJson(task.toJson()).exports.single;

      expect(back.at, DateTime.utc(2026, 8, 8, 20, 15));
      expect(back.total, 6);
      expect(back.succeeded, 5);
      expect(back.outputDir, '/Users/me/Movies/滴露');
      expect(back.allSucceeded, isFalse);
    });

    test('一个项目可以导很多次，按发生顺序攒着', () {
      final task = _task(exports: [
        ExportRecord(
            at: DateTime.utc(2026, 8, 8), total: 2, succeeded: 2, outputDir: '/a'),
        ExportRecord(
            at: DateTime.utc(2026, 8, 9), total: 3, succeeded: 3, outputDir: '/b'),
      ]);

      final back = RenewTask.fromJson(task.toJson()).exports;

      expect(back, hasLength(2));
      expect(back.last.outputDir, '/b', reason: '最后一条就是最近一次');
    });

    test('老任务没有这一段时读出来是空的，不炸', () {
      final json = _task().toJson()..remove('exports');

      expect(RenewTask.fromJson(json).exports, isEmpty);
    });

    test('畸形的那一条跳过，不牵连整份任务', () {
      final json = _task().toJson()
        ..['exports'] = [
          {'at': '2026-08-08T00:00:00.000Z', 'outputDir': '/a'},
          {'outputDir': '/没有时间'},
          {'at': '不是时间', 'outputDir': '/b'},
          '这根本不是对象',
        ];

      final back = RenewTask.fromJson(json).exports;

      expect(back, hasLength(1));
      expect(back.single.outputDir, '/a');
      expect(back.single.total, 0, reason: '缺的数字按 0 读，不猜');
    });
  });

  group('项目本身没有终态', () {
    test('只有「分析中 → 可编辑」两个阶段', () {
      expect(RenewTaskStatus.values,
          [RenewTaskStatus.analyzing, RenewTaskStatus.ready]);
    });

    test('导出过的项目仍然是可编辑——明天换一批素材还能再导', () {
      final task = _task(exports: [
        ExportRecord(
            at: DateTime.utc(2026, 8, 8), total: 2, succeeded: 2, outputDir: '/a'),
      ]);

      expect(task.status, RenewTaskStatus.ready);
    });
  });
}

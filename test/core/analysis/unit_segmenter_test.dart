import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/unit_segmenter.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';

SemanticUnit _unit({int startMs = 4000}) => SemanticUnit(
      uid: 'u1',
      index: 1,
      startMs: startMs,
      endMs: startMs + 6000,
      transcript: '',
      hasSource: false,
    );

void main() {
  group('把底片内的切点变成镜头', () {
    test('切点落在底片自己的时间轴上，摆进来时加上单元起点', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(),
        baseDurationMs: 6000,
        cutsMs: [2000, 4000],
        fps: 25,
      );

      expect(shots.map((s) => (s.startMs, s.endMs)).toList(), [
        (4000, 6000),
        (6000, 8000),
        (8000, 10000),
      ]);
    });

    test('无缝盖满这一段：首尾一定补齐', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(startMs: 0),
        baseDurationMs: 5000,
        cutsMs: [3000],
        fps: 25,
      );

      expect(shots.first.startMs, 0);
      expect(shots.last.endMs, 5000);
      for (var i = 1; i < shots.length; i++) {
        expect(shots[i].startMs, shots[i - 1].endMs, reason: '中间不许有缝');
      }
    });

    test('一个切点都没有：整段就是一镜，不是零镜', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(startMs: 0),
        baseDurationMs: 5000,
        cutsMs: const [],
        fps: 25,
      );

      expect(shots.length, 1);
      expect(shots.single.endMs, 5000);
    });

    test('切点吸到帧上——卡片按帧显示，落在帧缝里会差一帧', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(startMs: 0),
        baseDurationMs: 6000,
        cutsMs: [2013],
        fps: 25, // 一帧 40ms
      );

      expect(shots.first.endMs % 40, 0);
    });

    test('挨得太近的切点丢掉：碎成半秒一格没法看也没法挑', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(startMs: 0),
        baseDurationMs: 6000,
        cutsMs: [2000, 2100, 2200],
        fps: 25,
      );

      expect(shots.length, 2, reason: '2100 和 2200 离 2000 不足 500ms');
    });

    test('贴着片尾的切点丢掉：最后那一格不能只有几十毫秒', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(startMs: 0),
        baseDurationMs: 6000,
        cutsMs: [5900],
        fps: 25,
      );

      expect(shots.length, 1);
    });

    test('切点顺序乱给也能排好', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(startMs: 0),
        baseDurationMs: 9000,
        cutsMs: [6000, 2000, 4000],
        fps: 25,
      );

      expect(shots.map((s) => s.startMs).toList(), [0, 2000, 4000, 6000]);
    });

    test('底片时长为 0（探不出来）：不给假镜头', () {
      final shots = UnitSegmenter.shotsFromCuts(
        unit: _unit(),
        baseDurationMs: 0,
        cutsMs: [1000],
        fps: 25,
      );

      expect(shots, isEmpty);
    });
  });
}

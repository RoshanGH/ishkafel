import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/analysis/shot_boundary_detector.dart';
import 'package:ishkafel/core/analysis/shot_boundary_finder.dart';
import 'package:ishkafel/core/analysis/unit_segmenter.dart';
import 'package:ishkafel/core/replacement/unit_base.dart';
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

  group('底片切出来的镜头，该有的一样不少', () {
    test('这一刀怎么定出来的也要记下来——属性面板靠它回看依据', () async {
      // 全片切分会把画面差异分数、是否经复核贴到镜头上
      // （AnalysisPipeline._withBoundaryTrace）。底片切出来的镜头不能少这一样，
      // 否则同样是一刀，原片切的能回看、底片切的点开是空的
      ShotBoundaryFinder.lastDetails = {
        3000: const ShotBoundaryCandidate(
            ms: 3000,
            sceneScore: 0.62,
            histDistance: 0.41,
            confidence: BoundaryConfidence.confirmed),
      };
      addTearDown(() => ShotBoundaryFinder.lastDetails = const {});

      final segmenter = UnitSegmenter(scenes: _FixedScenes([3000]));
      final shots = await segmenter.segment(
        unit: _unit(startMs: 4000),
        base: const UnitBase(
            path: '/m/7.mp4', startMs: 0, endMs: 6000, candidateId: 7),
        taskId: 't1',
        fps: 25,
      );

      // 第二镜的起点就是那一刀（单元起点 4000 + 底片内 3000）
      expect(shots[1].startMs, 7000);
      expect(shots[1].boundaryTrace?.sceneScore, 0.62);
      expect(shots[1].boundaryTrace?.decision, 'confirmed');
    });

    test('查表用的是底片内毫秒，不是单元坐标——查错就一条都贴不上', () async {
      ShotBoundaryFinder.lastDetails = {
        3000: const ShotBoundaryCandidate(
            ms: 3000,
            sceneScore: 0.5,
            histDistance: 0.3,
            confidence: BoundaryConfidence.uncertain),
      };
      addTearDown(() => ShotBoundaryFinder.lastDetails = const {});

      final shots = await UnitSegmenter(scenes: _FixedScenes([3000])).segment(
        unit: _unit(startMs: 12345),
        base: const UnitBase(
            path: '/m/7.mp4', startMs: 0, endMs: 6000, candidateId: 7),
        taskId: 't1',
        fps: 25,
      );

      expect(shots[1].boundaryTrace, isNotNull,
          reason: '单元起点不为 0 时也要贴得上');
      expect(shots[1].boundaryTrace?.decision, 'reviewed');
    });

    test('切点没落在帧上也要贴得上——这是查不中的那个老坑', () async {
      // 检出来的是 3435，帧对齐后镜头边界是 3433。不做对齐就一条都贴不上
      ShotBoundaryFinder.lastDetails = {
        3435: const ShotBoundaryCandidate(
            ms: 3435,
            sceneScore: 0.7,
            histDistance: 0.6,
            confidence: BoundaryConfidence.confirmed),
      };
      addTearDown(() => ShotBoundaryFinder.lastDetails = const {});

      final shots = await UnitSegmenter(scenes: _FixedScenes([3435])).segment(
        unit: _unit(startMs: 0),
        base: const UnitBase(
            path: '/m/7.mp4', startMs: 0, endMs: 9000, candidateId: 7),
        taskId: 't1',
        fps: 30,
      );

      expect(shots[1].startMs, isNot(3435), reason: '镜头边界是吸到帧上的');
      expect(shots[1].boundaryTrace?.sceneScore, 0.7,
          reason: '照样要贴得上——查表前两边都对齐过');
    });

    test('没有判定明细（退回了基础场景检测）：不硬造，留空', () async {
      ShotBoundaryFinder.lastDetails = const {};
      final shots = await UnitSegmenter(scenes: _FixedScenes([3000])).segment(
        unit: _unit(startMs: 0),
        base: const UnitBase(
            path: '/m/7.mp4', startMs: 0, endMs: 6000, candidateId: 7),
        taskId: 't1',
        fps: 25,
      );

      expect(shots.every((s) => s.boundaryTrace == null), isTrue);
    });
  });
}

/// 固定切点的场景检测：不碰 ffmpeg
class _FixedScenes implements SceneDetector {
  final List<int> cuts;
  const _FixedScenes(this.cuts);

  @override
  Future<List<int>> detect(String videoPath) async => cuts;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
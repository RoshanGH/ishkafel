import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// **有原片的真实单元**做了整体替换之后，同样能切成分镜再精修。
///
/// 它和插入段的区别是：`startMs`/`endMs` 仍然指着原片那一段（4 秒），
/// 而底片是一条 6 秒的素材——两者不相等。这一组测试盯的就是这个差值
/// 有没有在某处被当成同一个数。
void main() {
  /// U0 取自原片 0~10000；U1 取自原片 10000~14000（4 秒），
  /// 底片换成 6 秒的素材 7 并按它切成三镜
  List<SemanticUnit> units() => [
        const SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 0,
            endMs: 10000,
            transcript: '第一句',
            shots: [Shot(startMs: 0, endMs: 10000)]),
        const SemanticUnit(
          uid: 'u1',
          index: 1,
          startMs: 10000,
          endMs: 14000,
          transcript: '第二句',
          baseCandidateId: 7,
          shots: [
            Shot(startMs: 10000, endMs: 12000),
            Shot(startMs: 12000, endMs: 14480),
            Shot(startMs: 14480, endMs: 16000),
          ],
        ),
      ];

  List<UnitReplacement> plans({Map<int, List<int>> shotPicks = const {}}) => [
        UnitReplacement.keepOriginal(),
        shotPicks.isEmpty
            ? UnitReplacement.whole([7], previewId: 7)
            : UnitReplacement.perShot(shotPicks),
      ];

  ComposedTimeline axis() =>
      ComposedTimeline.of(units: units(), wholeDurations: const {1: 6000});

  group('成片时间轴：这一段按底片长度算，不是原片那 4 秒', () {
    test('它在成片里占 6 秒', () {
      expect(axis().startOf(1), 10000);
      expect(axis().durationOf(1), 6000);
    });

    test('三镜的成片位置一个不错，末尾正好收在 16 秒', () {
      final a = axis();
      expect([
        a.composedShotStart(1, 0),
        a.composedShotStart(1, 1),
        a.composedShotStart(1, 2),
      ], [10000, 12000, 14480]);
      expect(a.composedShotEnd(1, 2), 16000);
    });

    test('全片因此比原片长', () {
      expect(axis().totalMs, 16000);
    });

    test('有自己的镜头，时间线不画成一整块', () {
      expect(axis().hasOwnShots(1), isTrue);
      expect(axis().isSolidBlock(1), isFalse);
    });
  });

  group('预览', () {
    test('这一段放的是素材，不是原片那 4 秒', () {
      final plan = TrackPlanBuilder.build(
        sourcePath: '/v/src.mp4',
        units: units(),
        replacements: plans(),
        materials: const {7: LocalMaterial(path: '/m/7.mp4', durationMs: 6000)},
      );

      final fromMaterial =
          plan.video.where((s) => s.source == '/m/7.mp4').toList();
      expect(fromMaterial, isNotEmpty);
      expect(fromMaterial.first.inMs, 0, reason: '从素材开头起，不是从 10000');
      expect(fromMaterial.fold<int>(0, (n, s) => n + s.durationMs), 6000);
    });

    test('前一段照旧放原片，位置没被挤歪', () {
      final plan = TrackPlanBuilder.build(
        sourcePath: '/v/src.mp4',
        units: units(),
        replacements: plans(),
        materials: const {7: LocalMaterial(path: '/m/7.mp4', durationMs: 6000)},
      );

      expect(plan.video.first.source, '/v/src.mp4');
      expect(plan.video.first.atMs, 0);
      expect(plan.video.first.durationMs, 10000);
    });
  });

  group('导出', () {
    List<ExportSegment> segs({Map<int, List<int>> shotPicks = const {}}) =>
        ExportPlanner.enumerate(
          units: units(),
          replacements: plans(shotPicks: shotPicks),
          materialDurations: const {7: 6000, 9: 3000},
        ).single.segments.where((s) => s.unitIndex == 1).toList();

    test('拆成三段，各自记着从底片第几毫秒剪', () {
      expect(segs().map((s) => (s.baseCandidateId, s.baseStartMs)).toList(),
          [(7, 0), (7, 2000), (7, 4480)]);
    });

    test('三段加起来正好是底片的长度', () {
      expect(segs().fold<int>(0, (n, s) => n + s.durationMs), 6000);
    });

    test('换掉中间一镜：那一镜用新素材，前后两镜还是底片', () {
      final s = segs(shotPicks: {
        1: [9]
      });

      expect(s[0].baseCandidateId, 7);
      expect(s[1].candidateId, 9);
      expect(s[2].baseCandidateId, 7);
      expect(s[2].baseStartMs, 4480);
    });
  });
}

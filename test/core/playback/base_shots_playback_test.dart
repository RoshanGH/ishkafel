import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 插入段挑了素材、又把它切成镜头之后，预览要一格格地放**那条素材**
/// ——而不是整条塞进去，更不是跑去原片同一个时间点取。
void main() {
  /// U0 取自原片 0~4000；U1 是插入段，占位 4000~10000，
  /// 底片是素材 7（6 秒），按它切成两镜
  List<SemanticUnit> units() => [
        const SemanticUnit(
          uid: 'u0',
          index: 0,
          startMs: 0,
          endMs: 4000,
          transcript: '第一句',
          shots: [Shot(startMs: 0, endMs: 4000)],
        ),
        const SemanticUnit(
          uid: 'u1',
          index: 1,
          startMs: 4000,
          endMs: 10000,
          transcript: '',
          hasSource: false,
          baseCandidateId: 7,
          shots: [
            Shot(startMs: 4000, endMs: 6500),
            Shot(startMs: 6500, endMs: 10000),
          ],
        ),
      ];

  TrackPlan build({
    Map<int, List<int>> shotPicks = const {},
    Map<String, String> speedFitted = const {},
  }) =>
      TrackPlanBuilder.build(
        sourcePath: '/v/src.mp4',
        units: units(),
        replacements: [
          UnitReplacement.keepOriginal(),
          shotPicks.isEmpty
              ? UnitReplacement.whole([7], previewId: 7)
              : UnitReplacement.perShot(shotPicks),
        ],
        materials: const {
          7: LocalMaterial(path: '/m/7.mp4', durationMs: 6000),
          9: LocalMaterial(path: '/m/9.mp4', durationMs: 3000),
        },
        speedFitted: speedFitted,
      );

  test('画面取自那条素材，不是原片', () {
    final plan = build();

    expect(plan.video.any((s) => s.source == '/m/7.mp4'), isTrue);
  });

  test('从素材开头起、盖满整段——两镜连着，合成一段放是对的', () {
    final plan = build();
    final fromMaterial =
        plan.video.where((s) => s.source == '/m/7.mp4').toList();

    expect(fromMaterial.first.inMs, 0);
    expect(
        fromMaterial.fold<int>(0, (n, s) => n + s.durationMs), 6000,
        reason: '两镜 2500 + 3500，正好是这条素材的长度');
  });

  test('中间一镜换掉之后，剩下的仍然从素材上取——而且是素材内偏移', () {
    final plan = build(
      shotPicks: {
        0: [9]
      },
      speedFitted: {'1/0': '/fit/u1s0.mp4'},
    );
    final fromMaterial =
        plan.video.where((s) => s.source == '/m/7.mp4').toList();

    expect(fromMaterial.length, 1, reason: '第一镜换掉了，只剩第二镜');
    expect(fromMaterial.single.inMs, 2500,
        reason: '第二镜在单元里从 6500 起，单元起点 4000，素材内就是 2500');
  });

  test('原片那一段照旧从原片取', () {
    final plan = build();

    expect(plan.video.first.source, '/v/src.mp4');
    expect(plan.video.first.inMs, 0);
  });

  test('这一段不算「放不了」——它有底片', () {
    final plan = build();

    expect(plan.unplayable, isEmpty);
    expect(plan.skippedEmptyUnits, isEmpty);
  });

  test('声音也取自素材，不是跑去原片同一个时间点剪', () {
    final plan = build();

    expect(plan.voice.any((s) => s.source == '/m/7.mp4'), isTrue);
    final fromMaterial =
        plan.voice.where((s) => s.source == '/m/7.mp4').toList();
    expect(fromMaterial.first.inMs, 0);
  });
}

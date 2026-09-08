import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// **手加的台词语义单元没有原片可垫。**
///
/// 2026-09-08 真机，用户原话：「添加的台词语义单元不能正常播放」。
/// 手加的单元在原片里根本不存在，它的 startMs/endMs 只是时间线上的占位，
/// 落在原片时长之外。预览却照着这段区间去原片里取画面——取的是一段不存在的
/// 时间，播出来是黑的、或者干脆卡住。
///
/// 判据必须是「**这个单元**有没有原片来源」，不是「这条任务有没有原片」：
/// 同一条任务里两种单元现在是并存的。
void main() {
  /// 原片 20s；U2 是手加的，占位排在 20s~30s（原片里没有这一段）
  List<SemanticUnit> units() => const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 20000,
          transcript: '原片这一段',
          shots: [Shot(startMs: 0, endMs: 20000)],
        ),
        SemanticUnit(
          index: 1,
          startMs: 20000,
          endMs: 30000,
          transcript: '',
          hasSource: false,
        ),
      ];

  TrackPlan build({
    List<UnitReplacement> replacements = const [],
    Map<int, LocalMaterial> materials = const {},
  }) =>
      TrackPlanBuilder.build(
        units: units(),
        sourcePath: '/v/src.mp4',
        replacements: replacements,
        materials: materials,
      );

  test('没挑素材的手加单元：跳过并如实记下来，不去原片里取不存在的一段', () {
    final plan = build();

    expect(plan.skippedEmptyUnits, contains(1),
        reason: '不记下来的话，人只看到「播到这儿就黑了」，无从判断是坏了还是没挑素材');
    expect(plan.video.any((s) => s.sourceStartMs >= 20000), isFalse,
        reason: '原片只有 20s，取 20s 之后的画面是取一段不存在的时间');
  });

  test('挑了整体替换的手加单元：正常播候选素材', () {
    final plan = build(
      replacements: [
        UnitReplacement.keepOriginal(),
        UnitReplacement.whole(const [7], previewId: 7),
      ],
      materials: {7: const LocalMaterial(path: '/m/7.mp4', durationMs: 8000)},
    );

    expect(plan.skippedEmptyUnits, isNot(contains(1)));
    expect(plan.video.any((s) => s.source == '/m/7.mp4'), isTrue,
        reason: '素材挑好了就该能播——这是手加单元唯一的活路');
  });

  test('挑了素材但还没下到本地：跳过并记下来，不是静默黑屏', () {
    final plan = build(
      replacements: [
        UnitReplacement.keepOriginal(),
        UnitReplacement.whole(const [7], previewId: 7),
      ],
      materials: const {}, // 还没下下来
    );

    expect(plan.skippedEmptyUnits, contains(1),
        reason: '素材还没到本地时，界面要说「这一段还没准备好」，'
            '而不是让人对着一段黑画面猜');
  });

  test('原片里的单元照旧从原片取，没受影响', () {
    final plan = build();

    expect(plan.video.any((s) => s.source == '/v/src.mp4'), isTrue);
  });
}

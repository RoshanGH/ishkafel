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

  group('没素材的单元照样占成片时间——不许把它从时间轴上抹掉', () {
    // 2026-09-08 真机，用户原话：「我播放的时候，你竟然是从第二个台词语义
    // 单元开始播放……你不是应该提醒吗？你必须得选个视频，他这个部分才能播放。
    // 然后你看末尾也没对齐。」
    //
    // 上一版为了不去原片里取一段不存在的时间，把这些单元跳过了——结果变成
    // 另一种静默降级：它在成片里凭空消失，后面全部前移 10s，时间线画到
    // 01:46 而播放器只到 01:36。跳过的是**画面**，不是**时间**。

    test('它在成片里占的那一段，后面的单元不许往前挪', () {
      final plan = build();

      // U1 原片 0–20s，U2 手加 10s。手加的排在后面，不影响 U1
      final first = plan.video.first;
      expect(first.atMs, 0);
      expect(plan.totalMs, 30000,
          reason: '成片是 20s 原片 + 10s 待填 = 30s。'
              '按画面轨末尾算的话只有 20s，末尾就和时间线对不上了');
    });

    test('点名哪一段放不了、在成片的哪个区间——播到那儿要停下来说话', () {
      final plan = build();

      expect(plan.unplayable, hasLength(1));
      expect(plan.unplayable.single.unitIndex, 1);
      expect(plan.unplayable.single.startMs, 20000);
      expect(plan.unplayable.single.endMs, 30000);
    });

    test('排在最前面时，后面的单元从它之后开始——不是从 0 开始', () {
      final units = [
        const SemanticUnit(
            index: 0,
            startMs: 20000,
            endMs: 30000,
            transcript: '',
            hasSource: false),
        const SemanticUnit(
            index: 1,
            startMs: 0,
            endMs: 20000,
            transcript: '原片这一段',
            shots: [Shot(startMs: 0, endMs: 20000)]),
      ];
      final plan = TrackPlanBuilder.build(
        units: units,
        sourcePath: '/v/src.mp4',
        replacements: const [],
        materials: const {},
      );

      expect(plan.unplayable.single.startMs, 0);
      expect(plan.video.first.atMs, 10000,
          reason: '真机上这里是 0——于是一按播放就直接从 U2 开始，'
              '用户以为软件把他加的那一段吃了');
    });

    test('挑了素材就不在这张名单上', () {
      final plan = build(
        replacements: [
          UnitReplacement.keepOriginal(),
          UnitReplacement.whole(const [7], previewId: 7),
        ],
        materials: {7: const LocalMaterial(path: '/m/7.mp4', durationMs: 8000)},
      );

      expect(plan.unplayable, isEmpty);
    });
  });

  group('垫上黑场之后，EDL 里就不再有洞', () {
    // EDL 没有「空档」这个概念——留洞会被压掉，从那儿起后面所有内容都提前
    // 一截：时间线画到 01:47、播放器只走到 01:37，双击最后一格跳过去落在
    // 片尾（2026-09-08 真机：「U6 不能正常播放」）。
    test('垫片进了画面轨和声音轨，位置与时长都对得上', () {
      final plan = TrackPlanBuilder.build(
        units: units(),
        sourcePath: '/v/src.mp4',
        replacements: const [],
        materials: const {},
        gapClips: const {1: '/tmp/gap.mp4'},
      );

      final gap = plan.video.where((s) => s.source == '/tmp/gap.mp4').single;
      expect(gap.atMs, 20000);
      expect(gap.durationMs, 10000);
      expect(gap.volume, 0, reason: '画面轨不出声，声音一律走口播轨');

      expect(plan.voice.where((s) => s.source == '/tmp/gap.mp4').single.atMs,
          20000,
          reason: '声音轨留洞的表现是「最后几个字一直重复」，同样得垫');
    });

    test('画面轨首尾相接，没有洞', () {
      final plan = TrackPlanBuilder.build(
        units: units(),
        sourcePath: '/v/src.mp4',
        replacements: const [],
        materials: const {},
        gapClips: const {1: '/tmp/gap.mp4'},
      );

      var at = plan.video.first.atMs;
      for (final s in plan.video) {
        expect(s.atMs, at, reason: 'EDL 会把洞压掉，后面的内容全部提前');
        at += s.durationMs;
      }
      expect(at, plan.totalMs);
    });

    test('垫上了也照样点名——人还是要知道这一段是空的', () {
      final plan = TrackPlanBuilder.build(
        units: units(),
        sourcePath: '/v/src.mp4',
        replacements: const [],
        materials: const {},
        gapClips: const {1: '/tmp/gap.mp4'},
      );

      expect(plan.unplayable.single.unitIndex, 1,
          reason: '垫黑场是为了时间对得上，不是把问题盖过去');
    });
  });
}

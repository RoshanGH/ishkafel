import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/export/shot_audio_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 「替换分镜的声音」这一层，**预览也要播**。
///
/// 真机事故（2026-09-11）：这一层只在导出那条路上有，预览压根没有它。
/// 用户在预览里听着一切正常、挑好了组合，一导出发现多了一层声音，而且
/// 位置和音量都不对。他找不出原因，因为预览就是他唯一的判断依据。
///
/// 用户原话：「让我预览和导出的成品一定要保持一致。」
///
/// 预览里这一层走的是 [MultitrackPlayback] 的原声轨，它读的是**画面段自己
/// 的音量**（画面轨本身永远静音）。所以这里钉的就是：画面段的音量必须等于
/// 这一镜算出来的素材声音量。
const _src = '/v/原片.mp4';
const _material = '/m/71.mp4';

/// U1 两镜：S1 换过素材，S2 没换
List<SemanticUnit> _units({
  MaterialAudioMode? s1Mode,
  double? s1Volume,
}) =>
    [
      SemanticUnit(
        uid: 'u0',
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [
          Shot(
            startMs: 0,
            endMs: 2000,
            materialAudioMode: s1Mode,
            materialAudioVolume: s1Volume,
          ),
          const Shot(startMs: 2000, endMs: 4000),
        ],
      ),
    ];

TrackPlan _build({
  MaterialAudioMode? s1Mode,
  double? s1Volume,
  MaterialAudioSetting taskDefault = MaterialAudioSetting.off,
  bool replaced = true,
}) =>
    TrackPlanBuilder.build(
      sourcePath: _src,
      units: _units(s1Mode: s1Mode, s1Volume: s1Volume),
      replacements: [
        if (replaced)
          UnitReplacement.perShot(const {0: [71]}, previewIds: const {0: 71})
        else
          UnitReplacement.keepOriginal(),
      ],
      materials: const {71: LocalMaterial(path: _material, durationMs: 6000)},
      speedFitted: const {'0/0': '/fit/0_0.mp4'},
      materialAudio: taskDefault,
    );

/// 换过素材的那一镜在预览里的画面段
TrackSegment _replacedShot(TrackPlan plan) =>
    plan.video.firstWhere((s) => s.source == '/fit/0_0.mp4');

void main() {
  group('预览要播替换分镜自己的声音', () {
    test('任务默认「原声」时，那一镜在预览里就该出声', () {
      final plan = _build(
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.original),
      );

      expect(_replacedShot(plan).volume,
          closeTo(MaterialAudioSetting.defaultVolume, 1e-9),
          reason: '导出会把这一层叠进成片，预览不播就等于让人照着错的判断');
    });

    test('任务默认「不播放」时不出声', () {
      final plan = _build(taskDefault: MaterialAudioSetting.off);

      expect(_replacedShot(plan).volume, 0);
    });

    test('这一镜单独调过音量时，预览按这一镜的来', () {
      final plan = _build(
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.original),
        s1Volume: 0.6,
      );

      expect(_replacedShot(plan).volume, closeTo(0.6, 1e-9));
    });

    test('这一镜单独设成「不播放」时，只有它不出声', () {
      final plan = _build(
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.original),
        s1Mode: MaterialAudioMode.none,
      );

      expect(_replacedShot(plan).volume, 0);
    });

    test('没换素材的镜头一律不出声——那是原片，没有「素材的声音」可言', () {
      final plan = _build(
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.original),
      );

      for (final seg in plan.video.where((s) => s.source != '/fit/0_0.mp4')) {
        expect(seg.volume, 0, reason: '${seg.source} 不该出声');
      }
    });
  });

  group('选了要分离的那一档：预览退回素材原混音，但必须说出来', () {
    // 预览里这一层读的是变速切片，切片带的是素材**原混音**；而导出用的是
    // 分离出来的那一路。不说的话人听到的和导出的不是一回事，
    // 而他正照着预览挑组合
    for (final mode in [MaterialAudioMode.vocals, MaterialAudioMode.background]) {
      test('${mode.label}：点名是哪一镜', () {
        final plan = _build(
          taskDefault:
              const MaterialAudioSetting(mode: MaterialAudioMode.original),
          s1Mode: mode,
        );

        expect(plan.materialStemMissing, ['U1·S1'],
            reason: '选了「${mode.label}」，预览只能放原混音，得告诉人');
      });
    }

    test('「原声」档不用说——预览放的本来就是它', () {
      final plan = _build(
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.original),
      );

      expect(plan.materialStemMissing, isEmpty);
    });

    test('「不播放」档也不用说——它本来就没声音', () {
      final plan = _build(
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.original),
        s1Mode: MaterialAudioMode.none,
      );

      expect(plan.materialStemMissing, isEmpty);
    });
  });

  group('预览和导出对同一个方案给出同一个答案', () {
    test('位置、时长、音量三样都要对得上', () async {
      const taskDefault =
          MaterialAudioSetting(mode: MaterialAudioMode.original);
      final units = _units();
      final plan = _build(taskDefault: taskDefault);

      final exported = await planShotMaterialAudio(
        units: units,
        segments: [
          const ExportSegment(
            startMs: 0,
            endMs: 2000,
            unitIndex: 0,
            shotIndex: 0,
            candidateId: 71,
          ),
          const ExportSegment(
              startMs: 2000, endMs: 4000, unitIndex: 0, shotIndex: 1),
        ],
        taskDefault: taskDefault,
        timeline:
            ComposedTimeline.of(units: units, wholeDurations: const {}),
        resolveMaterial: (id) async => _material,
        probe: (path) async => 6000,
      );

      expect(exported, hasLength(1), reason: '只有 S1 换过素材');
      final previewed = _replacedShot(plan);

      expect(previewed.atMs, exported.single.composedStartMs);
      expect(previewed.durationMs, exported.single.durationMs);
      expect(previewed.volume, closeTo(exported.single.volume, 1e-9));
    });
  });
}

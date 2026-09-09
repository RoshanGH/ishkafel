import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/audio/vocal_separator.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/export/shot_audio_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// U1 = 0~2000（两镜：0~1000、1000~2000），U2 = 2000~5000
List<SemanticUnit> unitsWith({MaterialAudioMode? shotMode, double? shotVolume}) => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: 'U1',
        shots: [
          Shot(
            startMs: 0,
            endMs: 1000,
            materialAudioMode: shotMode,
            materialAudioVolume: shotVolume,
          ),
          const Shot(startMs: 1000, endMs: 2000),
        ],
      ),
      const SemanticUnit(
          index: 1, startMs: 2000, endMs: 5000, transcript: 'U2'),
    ];

const _seg = ExportSegment(
    startMs: 0, endMs: 1000, unitIndex: 0, shotIndex: 0, candidateId: 77);

Future<List<ShotMaterialAudio>> plan({
  required MaterialAudioSetting taskDefault,
  MaterialAudioMode? shotMode,
  double? shotVolume,
  List<ExportSegment> segments = const [_seg],
  int? candidateMs = 2000,
}) {
  final units = unitsWith(shotMode: shotMode, shotVolume: shotVolume);
  return planShotMaterialAudio(
    units: units,
    segments: segments,
    taskDefault: taskDefault,
    timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
    resolveMaterial: (id) async => '/mat/$id.mp4',
    separate: (path) async =>
        SeparatedAudio(vocalsPath: '$path.vocals.wav', backgroundPath: '$path.bg.wav'),
    probe: (_) async => candidateMs,
  );
}

void main() {
  group('挑出要保留原声的镜头', () {
    test('任务默认关、镜头也没设：一个都不叠', () async {
      expect(await plan(taskDefault: MaterialAudioSetting.off), isEmpty);
    });

    test('任务默认开：这一镜就要叠', () async {
      final r = await plan(
          taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original, volume: 0.3));

      expect(r.single.path, '/mat/77.mp4');
      expect(r.single.volume, 0.3);
    });

    test('镜头单独关掉，盖过任务的开', () async {
      final r = await plan(
          taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
          shotMode: MaterialAudioMode.none);

      expect(r, isEmpty);
    });

    test('任务关着，个别镜头单独开', () async {
      final r = await plan(
          taskDefault: MaterialAudioSetting.off,
          shotMode: MaterialAudioMode.original,
          shotVolume: 0.6);

      expect(r.single.volume, 0.6);
    });
  });

  group('四档各自放哪一路声音', () {
    test('人声：用分离出来的人声轨', () async {
      final r = await plan(
          taskDefault:
              const MaterialAudioSetting(mode: MaterialAudioMode.vocals));

      expect(r.single.path, '/mat/77.mp4.vocals.wav');
    });

    test('背景声：用分离出来的背景轨', () async {
      final r = await plan(
          taskDefault:
              const MaterialAudioSetting(mode: MaterialAudioMode.background));

      expect(r.single.path, '/mat/77.mp4.bg.wav');
    });

    test('原声：素材文件本身，不分离', () async {
      final r = await plan(
          taskDefault:
              const MaterialAudioSetting(mode: MaterialAudioMode.original));

      expect(r.single.path, '/mat/77.mp4');
    });

    test('不播放：这一镜根本不进列表', () async {
      expect(await plan(taskDefault: MaterialAudioSetting.off), isEmpty);
    });
  });

  group('分不出来就失败，绝不悄悄换一路声音', () {
    Future<List<ShotMaterialAudio>> withSeparator(
        Future<SeparatedAudio?> Function(String)? sep) {
      final units = unitsWith();
      return planShotMaterialAudio(
        units: units,
        segments: const [_seg],
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.background),
        timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
        resolveMaterial: (id) async => '/mat/$id.mp4',
        probe: (_) async => 1000,
        separate: sep,
      );
    }

    test('分离失败：点名是哪一镜、给出路，不退回原声', () async {
      await expectLater(
        withSeparator((_) async => null),
        throwsA(isA<StateError>().having((e) => e.message, '说明',
            allOf(contains('S1'), contains('背景声'), contains('原声')))),
        reason: '悄悄放原声的话，人要把片子导出来听一遍才发现声音不是他选的那个',
      );
    });

    test('压根没有分离能力：同样点名，并指路去装工具', () async {
      await expectLater(
        withSeparator(null),
        throwsA(isA<StateError>()
            .having((e) => e.message, '说明', contains('运行环境'))),
      );
    });

    test('选「原声」时没有分离能力也照常出片——它本来就不需要分离', () async {
      final units = unitsWith();
      final r = await planShotMaterialAudio(
        units: units,
        segments: const [_seg],
        taskDefault:
            const MaterialAudioSetting(mode: MaterialAudioMode.original),
        timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
        resolveMaterial: (id) async => '/mat/$id.mp4',
        probe: (_) async => 1000,
        separate: null,
      );

      expect(r.single.path, '/mat/77.mp4');
    });
  });

  group('声音参数必须和画面那一段一致', () {
    test('变速倍率跟画面同一套算法', () async {
      // 候选 2000ms 填 1000ms 的坑位 → 2×
      final r = await plan(
          taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original));

      expect(r.single.speedFactor, closeTo(2.0, 1e-9));
    });

    test('跳过开头那一截：剩下的整条铺满，声音跟着同一个倍率', () async {
      const seg = ExportSegment(
          startMs: 0,
          endMs: 1000,
          unitIndex: 0,
          shotIndex: 0,
          candidateId: 77,
          trimStartMs: 500);

      final r = await plan(
          taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
          segments: const [seg]);

      expect(r.single.speedFactor, closeTo(1.5, 1e-9),
          reason: '候选 2000ms、从 500ms 起还剩 1500ms，铺满 1000ms 的坑位就是 1.5×'
              '——画面那边算的也是这个数');
      expect(r.single.trimStartMs, 500, reason: '起点也要跟画面一致');
    });

    test('探不到候选时长就不变速，不拿猜的倍率去改速度', () async {
      final r = await plan(
          taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
          candidateMs: null);

      expect(r.single.speedFactor, 1.0);
    });
  });

  group('落在成片的哪个位置', () {
    test('单元在成片里的起点 + 镜头在单元内的偏移', () async {
      const seg = ExportSegment(
          startMs: 1000,
          endMs: 2000,
          unitIndex: 0,
          shotIndex: 1,
          candidateId: 77);
      final units = unitsWith();
      final r = await planShotMaterialAudio(
        units: units,
        segments: const [seg],
        taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
        timeline: ComposedTimeline.of(units: units, wholeDurations: const {}),
        resolveMaterial: (id) async => '/mat/$id.mp4',
    separate: (path) async =>
        SeparatedAudio(vocalsPath: '$path.vocals.wav', backgroundPath: '$path.bg.wav'),
        probe: (_) async => 1000,
      );

      expect(r.single.composedStartMs, 1000);
      expect(r.single.durationMs, 1000);
    });
  });

  group('不该走这条路的都跳过', () {
    test('整体替换（没有镜头下标）不走这里——它的声音本来就来自素材', () async {
      const whole =
          ExportSegment(startMs: 0, endMs: 2000, unitIndex: 0, candidateId: 77);

      expect(
          await plan(
              taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
              segments: const [whole]),
          isEmpty);
    });

    test('没换素材的镜头没有「素材原声」可言', () async {
      const original =
          ExportSegment(startMs: 0, endMs: 1000, unitIndex: 0, shotIndex: 0);

      expect(
          await plan(
              taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
              segments: const [original]),
          isEmpty);
    });

    test('下标越界的脏数据不崩', () async {
      const bad = ExportSegment(
          startMs: 0, endMs: 1000, unitIndex: 9, shotIndex: 9, candidateId: 77);

      expect(
          await plan(
              taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
              segments: const [bad]),
          isEmpty);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/export/export_plan.dart';
import 'package:ishkafel/core/export/shot_audio_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 视觉镜头替换里，**素材的画面和素材的声音必须走同一个倍率**。
///
/// 真机事故（2026-09-11）：一条 40.9 秒的素材放进 1.2 秒的坑位，取段起点 0。
/// 画面走 [ExportCommands.fitCandidateVideo]——它认「截得出坑位那么长就按
/// 1× 播」，于是放的是素材开头 1.2 秒的正常速度画面；声音走
/// [SpeedFit.effectiveFactor]——它认「从起点起剩下的整条压进坑位」，于是把
/// 整整 40.9 秒压成 1.2 秒、34× 快放。用户听到的是一串听不出是什么的噪音，
/// 而画面一切正常，错误日志里一个字都没有。
///
/// 倍率必须只有一个来源。这一组测试就钉这件事：同一段镜头，问画面拿到的
/// 倍率和问声音拿到的倍率必须相等。
void main() {
  /// 从画面命令的滤镜串里把倍率读回来（没有 setpts 就是 1×）
  double pictureFactor(List<String> args) {
    final vf = args[args.indexOf('-vf') + 1];
    final match = RegExp(r'setpts=PTS/([0-9.]+)').firstMatch(vf);
    return match == null ? 1.0 : double.parse(match.group(1)!);
  }

  Future<double> audioFactor({
    required int candidateMs,
    required int slotMs,
    required int? trimStartMs,
  }) async {
    final unit = SemanticUnit(
      index: 0,
      startMs: 0,
      endMs: slotMs,
      transcript: 'U1',
      shots: [Shot(startMs: 0, endMs: slotMs)],
    );
    final plans = await planShotMaterialAudio(
      units: [unit],
      segments: [
        ExportSegment(
          startMs: 0,
          endMs: slotMs,
          unitIndex: 0,
          shotIndex: 0,
          candidateId: 7,
          trimStartMs: trimStartMs,
        ),
      ],
      // 「原声」= 素材整条声音原样叠回来，这一档才有声音可谈
      taskDefault: const MaterialAudioSetting(mode: MaterialAudioMode.original),
      timeline: ComposedTimeline.of(units: [unit], wholeDurations: const {}),
      resolveMaterial: (id) async => '/m.mp4',
      probe: (path) async => candidateMs,
    );
    expect(plans, hasLength(1));
    return plans.single.speedFactor;
  }

  group('素材的画面与素材的声音同速', () {
    test('取段起点 0、素材比坑位长很多：34× 的画面配 34× 的声音，不能一个 1× 一个 34×',
        () async {
      const candidateMs = 40933;
      const slotMs = 1200;
      const trimStartMs = 0;

      final picture = pictureFactor(ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: slotMs,
        candidateDurationMs: candidateMs,
        trimStartMs: trimStartMs,
        out: '/o.mp4',
      ));
      final audio = await audioFactor(
        candidateMs: candidateMs,
        slotMs: slotMs,
        trimStartMs: trimStartMs,
      );

      expect(audio, closeTo(picture, 0.001),
          reason: '画面 $picture×、声音 $audio×——声画不同速，听到的是噪音');
    });

    test('取段起点在中段时同样要同速', () async {
      const candidateMs = 40933;
      const slotMs = 1200;
      const trimStartMs = 19866;

      final picture = pictureFactor(ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: slotMs,
        candidateDurationMs: candidateMs,
        trimStartMs: trimStartMs,
        out: '/o.mp4',
      ));
      final audio = await audioFactor(
        candidateMs: candidateMs,
        slotMs: slotMs,
        trimStartMs: trimStartMs,
      );

      expect(audio, closeTo(picture, 0.001),
          reason: '画面 $picture×、声音 $audio×');
    });

    test('没给取段起点（整条压进坑位）时也要同速', () async {
      const candidateMs = 4500;
      const slotMs = 3000;

      final picture = pictureFactor(ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: slotMs,
        candidateDurationMs: candidateMs,
        out: '/o.mp4',
      ));
      final audio = await audioFactor(
        candidateMs: candidateMs,
        slotMs: slotMs,
        trimStartMs: null,
      );

      expect(audio, closeTo(picture, 0.001),
          reason: '画面 $picture×、声音 $audio×');
    });

    test('素材比坑位短（要放慢撑满）时也要同速', () async {
      const candidateMs = 2400;
      const slotMs = 3000;

      final picture = pictureFactor(ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: slotMs,
        candidateDurationMs: candidateMs,
        trimStartMs: 0,
        out: '/o.mp4',
      ));
      final audio = await audioFactor(
        candidateMs: candidateMs,
        slotMs: slotMs,
        trimStartMs: 0,
      );

      expect(audio, closeTo(picture, 0.001),
          reason: '画面 $picture×、声音 $audio×');
    });
  });
}

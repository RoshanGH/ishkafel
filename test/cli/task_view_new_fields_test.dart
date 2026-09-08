import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// **存了却不报，是最要命的一种漏**。
///
/// `task_view` 是 Agent 读任务的唯一窗口。加了字段却不报出去，它查到的空
/// 看起来正好像「没问题」——于是照着一个错的前提往下干：以为每个单元都有
/// 原片、以为没人设过声音档位。
///
/// 这一批加了四个字段（单元的 hasSource、镜头的两个覆盖、任务级打底），
/// 这条测试盯着它们真的出现在 JSON 里。
RenewTask _task({
  bool hasSource = true,
  MaterialAudioMode? shotMode,
  double? shotVolume,
  MaterialAudioSetting materialAudio = MaterialAudioSetting.off,
}) =>
    RenewTask(
      id: 't1',
      name: '测试',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 7),
      updatedAt: DateTime.utc(2026, 9, 7),
      materialAudio: materialAudio,
      units: [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 1000,
          transcript: 'U1',
          hasSource: hasSource,
          shots: [
            Shot(
              startMs: 0,
              endMs: 1000,
              materialAudioMode: shotMode,
              materialAudioVolume: shotVolume,
            ),
          ],
        ),
      ],
    );

void main() {
  Map<String, dynamic> unitOf(RenewTask t) =>
      (taskToJson(t)['units'] as List).first as Map<String, dynamic>;
  Map<String, dynamic> shotOf(RenewTask t) =>
      ((unitOf(t)['shots'] as List).first) as Map<String, dynamic>;

  group('手动加的单元，Agent 要看得出来', () {
    test('原片上有它：报 true', () {
      expect(unitOf(_task())['hasSource'], isTrue);
    });

    test('手动加的：报 false——它没有台词，标签只能手填，还必须挑素材', () {
      expect(unitOf(_task(hasSource: false))['hasSource'], isFalse,
          reason: '不报的话 Agent 会以为它跟别的单元一样有原片可放，'
              '既不会去手填标签，也不知道不挑素材就导不出来');
    });
  });

  group('替换分镜的声音，Agent 要看得出来', () {
    test('全片打底报出来', () {
      final json = taskToJson(_task(
          materialAudio: const MaterialAudioSetting(
              mode: MaterialAudioMode.background, volume: 0.3)));

      expect(json['materialAudio'],
          {'mode': 'background', 'volume': 0.3});
    });

    test('镜头设了覆盖就报覆盖', () {
      final shot = shotOf(_task(
          shotMode: MaterialAudioMode.vocals, shotVolume: 0.6));

      expect(shot['materialAudioMode'], 'vocals');
      expect(shot['materialAudioVolume'], 0.6);
    });

    test('镜头没设覆盖就不报这两个字段——「跟随全片」和「明确设成某档」'
        '要分得开', () {
      final shot = shotOf(_task());

      expect(shot.containsKey('materialAudioMode'), isFalse);
      expect(shot.containsKey('materialAudioVolume'), isFalse);
    });
  });
}

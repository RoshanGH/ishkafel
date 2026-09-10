import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/audio/source_audio.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 「存了却不报」是最要命的一种漏——Agent 查到的空看起来正好像「没问题」。
///
/// 这一批加的是「原片这一镜的声音」：任务级打底、镜头级覆盖，
/// 以及**分离轨在不在盘上**（不报的话，它只能先设上再撞导出拦截）。
RenewTask _task({
  SourceAudioSetting sourceAudio = SourceAudioSetting.auto,
  MaterialAudioMode? shotMode,
  double? shotVolume,
  String? vocalsPath,
  String? backgroundPath,
}) =>
    RenewTask(
      id: 't1',
      name: '测试',
      sourcePath: '/v/a.mp4',
      status: RenewTaskStatus.ready,
      createdAt: DateTime.utc(2026, 9, 10),
      updatedAt: DateTime.utc(2026, 9, 10),
      sourceAudio: sourceAudio,
      vocalsPath: vocalsPath,
      backgroundPath: backgroundPath,
      units: [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 1000,
          transcript: 'U1',
          shots: [
            Shot(
                startMs: 0,
                endMs: 1000,
                sourceAudioMode: shotMode,
                sourceAudioVolume: shotVolume),
          ],
        ),
      ],
    );

Map<String, dynamic> _shot(Map<String, dynamic> json) =>
    ((json['units'] as List).first as Map<String, dynamic>)['shots'][0]
        as Map<String, dynamic>;

void main() {
  test('任务级打底报出来；自动状态不冒充某一档', () {
    final auto = taskToJson(_task())['sourceAudio'] as Map<String, dynamic>;
    expect(auto.containsKey('mode'), isFalse,
        reason: '自动 = 还没选过，报一个档位出去会被当成人选的');

    final picked = taskToJson(_task(
        sourceAudio:
            const SourceAudioSetting(mode: MaterialAudioMode.vocals)))['sourceAudio'];
    expect((picked as Map)['mode'], 'vocals');
  });

  test('镜头级覆盖报出来；没设过就不出现在 JSON 里', () {
    expect(_shot(taskToJson(_task())).containsKey('sourceAudioMode'), isFalse);

    final json = _shot(taskToJson(
        _task(shotMode: MaterialAudioMode.background, shotVolume: 0.4)));
    expect(json['sourceAudioMode'], 'background');
    expect(json['sourceAudioVolume'], 0.4);
  });

  test('分离轨在不在盘上要报——不报的话只能先设上再撞导出拦截', () {
    final dir = Directory.systemTemp.createTempSync('ishkafel_stems_view_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final vocals = File('${dir.path}/人声.wav')..writeAsStringSync('v');

    final stems = taskToJson(_task(
      vocalsPath: vocals.path,
      // 记着路径但文件已经不在了：换机器、清理过都会这样
      backgroundPath: '${dir.path}/没了.wav',
    ))['stems'] as Map<String, dynamic>;

    expect(stems['vocals'], isTrue);
    expect(stems['background'], isFalse,
        reason: '存了路径不等于文件还在，报的必须是「能不能用」');
  });
}

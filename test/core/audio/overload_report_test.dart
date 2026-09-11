import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 各层改成相加之后，叠出来可能过载。**报出来是哪一段**，不偷偷压音量。
///
/// 判据只看「叠加新添了多少」：原片母带本来就压到顶，真机上口播轨自己就有
/// 四万多个采样点贴在 0 dB，拿「峰值到 0」当判据等于每条片子都报。
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 2000), Shot(startMs: 2000, endMs: 4000)],
      ),
    ];

/// 造一个假 ffmpeg：合成命令照常落文件，量电平的命令按 [clipped] 回话。
///
/// [clipped] 是「文件路径前缀 → 这个文件贴顶的采样点数」；量到哪个文件就
/// 回哪个数
({AudioTrackBuilder builder, List<List<String>> calls}) _build(
  Directory dir, {
  required int Function(String path) clipped,
}) {
  final calls = <List<String>>[];
  return (
    builder: AudioTrackBuilder(
      run: (binary, args) async {
        calls.add(args);
        if (args.contains('volumedetect')) {
          final input = args[args.indexOf('-i') + 1];
          return ProcessResult(
            1,
            0,
            '',
            '[Parsed_volumedetect_0 @ 0x1] mean_volume: -10.4 dB\n'
                '[Parsed_volumedetect_0 @ 0x1] max_volume: 0.0 dB\n'
                '[Parsed_volumedetect_0 @ 0x1] histogram_0db: ${clipped(input)}\n',
          );
        }
        await File(args.last).writeAsString('wav');
        return ProcessResult(1, 0, '', '');
      },
      workDir: dir,
    ),
    calls: calls,
  );
}

const _shot = ShotMaterialAudio(
  path: '/m/71.mp4',
  speedFactor: 1.0,
  volume: 1.0,
  composedStartMs: 2000,
  durationMs: 2000,
  label: 'U1·S2',
);

void main() {
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('ishkafel_overload_');
    File('${temp.path}/71.mp4').writeAsStringSync('mp4');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('叠上去新添了可听见的过载：点名是哪一镜', () async {
    // 口播轨自己贴顶 49539 个点（原片母带就是压到顶的），叠完变成 +2000 个
    final fake = _build(temp,
        clipped: (path) => path.contains('mix_material') ? 51539 : 49539);

    final track = await fake.builder.build(
      sourcePath: '/v/原片.mp4',
      units: _units(),
      shotAudio: const [_shot],
    );

    expect(track.overloads, hasLength(1));
    expect(track.overloads.single, contains('U1·S2'),
        reason: '要点名是哪一镜，人才知道该调哪一层的音量');
  });

  test('只多出几个采样点不报——听不出来，报了只会让人学会无视警告', () async {
    final fake = _build(temp,
        clipped: (path) => path.contains('mix_material') ? 49546 : 49539);

    final track = await fake.builder.build(
      sourcePath: '/v/原片.mp4',
      units: _units(),
      shotAudio: const [_shot],
    );

    expect(track.overloads, isEmpty);
  });

  test('一层都没叠时连量都不用量——不做白花的活', () async {
    final fake = _build(temp, clipped: (_) => 49539);

    final track = await fake.builder.build(
      sourcePath: '/v/原片.mp4',
      units: _units(),
    );

    expect(track.overloads, isEmpty);
    expect(fake.calls.where((a) => a.contains('volumedetect')), isEmpty);
  });

  test('过载不该让导出失败——它是「你自己决定调哪一层」，不是错误', () async {
    final fake = _build(temp,
        clipped: (path) => path.contains('mix_material') ? 51539 : 49539);

    final track = await fake.builder.build(
      sourcePath: '/v/原片.mp4',
      units: _units(),
      shotAudio: const [_shot],
    );

    expect(track.path, isNotEmpty, reason: '音轨照样合出来');
    expect(track.bgmWarnings, isEmpty, reason: '过载不走「中止导出」那条通道');
  });
}

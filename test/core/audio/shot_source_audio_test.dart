import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/material_audio.dart';
import 'package:ishkafel/core/audio/source_audio.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// 「原片这一镜的声音」：主轨那一层也拆成四档。
///
/// 用户 2026-09-10：「我需要的是原片 S1 的口播和替换分镜的原声。
/// 只是我不想做这么定制化，我要把它拆成功能。」
///
/// U1 = 0~4000（S1 0~2000、S2 2000~4000）；S1 换过素材，S2 没换。
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
              sourceAudioMode: s1Mode,
              sourceAudioVolume: s1Volume),
          const Shot(startMs: 2000, endMs: 4000),
        ],
      ),
    ];

/// 每次 ffmpeg 调用的输入源（-i 后面第一个值）
List<String> _inputsOf(List<List<String>> calls) => [
      for (final a in calls)
        if (a.contains('-i')) a[a.indexOf('-i') + 1],
    ];

String _filtersOf(List<String> args) =>
    args.contains('-af') ? args[args.indexOf('-af') + 1] : '';

({AudioTrackBuilder builder, List<List<String>> calls}) _build() {
  final calls = <List<String>>[];
  final work = Directory.systemTemp.createTempSync('ishkafel_srcaudio_');
  addTearDown(() => work.deleteSync(recursive: true));
  return (
    builder: AudioTrackBuilder(
      workDir: work,
      run: (bin, args) async {
        calls.add(args);
        File(args.last).writeAsStringSync('x');
        return ProcessResult(1, 0, '', '');
      },
    ),
    calls: calls,
  );
}

/// 分离轨要真的在盘上——装配层会 existsSync 检查
({String vocals, String background}) _stems() {
  final dir = Directory.systemTemp.createTempSync('ishkafel_stems_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final vocals = File('${dir.path}/人声.wav')..writeAsStringSync('v');
  final background = File('${dir.path}/背景.wav')..writeAsStringSync('b');
  return (vocals: vocals.path, background: background.path);
}

void main() {
  test('没设过 = 自动：还是原混音，一个字节都不动', () async {
    final b = _build();
    final stems = _stems();

    await b.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(),
      vocalsPath: stems.vocals,
      backgroundPath: stems.background,
      replacedShots: const {(0, 0)},
    );

    expect(_inputsOf(b.calls), everyElement(isNot(stems.vocals)));
    expect(_inputsOf(b.calls), everyElement(isNot(stems.background)));
  });

  test('这一镜选「人声」：只有它读人声轨，旁边那一镜照旧原混音', () async {
    final b = _build();
    final stems = _stems();

    await b.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(s1Mode: MaterialAudioMode.vocals),
      vocalsPath: stems.vocals,
      backgroundPath: stems.background,
      replacedShots: const {(0, 0)},
    );

    final inputs = _inputsOf(b.calls);
    expect(inputs.where((i) => i == stems.vocals), hasLength(1));
    expect(inputs.where((i) => i == '/v/a.mp4'), hasLength(1),
        reason: 'S2 没换素材，照旧走原混音');
  });

  test('选「背景声」读背景轨', () async {
    final b = _build();
    final stems = _stems();

    await b.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(s1Mode: MaterialAudioMode.background),
      vocalsPath: stems.vocals,
      backgroundPath: stems.background,
      replacedShots: const {(0, 0)},
    );

    expect(_inputsOf(b.calls), contains(stems.background));
  });

  test('选「不播放」垫等长静音——不能少拼一段', () async {
    final b = _build();

    await b.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(s1Mode: MaterialAudioMode.none),
      replacedShots: const {(0, 0)},
    );

    final silence = b.calls.where((a) => a.join(' ').contains('anullsrc'));
    expect(silence, hasLength(1), reason: '少拼一段的话后面所有内容会整体提前');
    // 2000ms 的坑位就该垫 2 秒
    expect(silence.single[silence.single.indexOf('-t') + 1],
        startsWith('2.0'));
  });

  test('没换素材的镜头不受影响——连档位都不该起作用', () async {
    final b = _build();
    final stems = _stems();

    await b.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(s1Mode: MaterialAudioMode.vocals),
      vocalsPath: stems.vocals,
      backgroundPath: stems.background,
      // 这一次 S1 没换素材
      replacedShots: const {},
    );

    expect(_inputsOf(b.calls), everyElement(isNot(stems.vocals)),
        reason: '没替换分镜就没有这回事（用户原话）');
  });

  test('全片打底：镜头没单独设就跟着它走', () async {
    final b = _build();
    final stems = _stems();

    await b.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(),
      vocalsPath: stems.vocals,
      backgroundPath: stems.background,
      replacedShots: const {(0, 0)},
      sourceAudio: const SourceAudioSetting(mode: MaterialAudioMode.vocals),
    );

    expect(_inputsOf(b.calls), contains(stems.vocals));
  });

  test('音量压过后进滤镜链；满音量时一道滤镜都不插', () async {
    final loud = _build();
    await loud.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(s1Mode: MaterialAudioMode.original),
      replacedShots: const {(0, 0)},
    );
    expect(loud.calls.map(_filtersOf), everyElement(isNot(contains('volume='))));

    final quiet = _build();
    await quiet.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(s1Mode: MaterialAudioMode.original, s1Volume: 0.3),
      replacedShots: const {(0, 0)},
    );
    expect(quiet.calls.map(_filtersOf).where((f) => f.contains('volume=0.3')),
        hasLength(1));
  });

  test('配了乐又手选「原声」：按人选的来，不替他改成人声', () async {
    final b = _build();
    final stems = _stems();

    await b.builder.build(
      sourcePath: '/v/a.mp4',
      units: _units(s1Mode: MaterialAudioMode.original),
      vocalsPath: stems.vocals,
      backgroundPath: stems.background,
      replacedShots: const {(0, 0)},
      bgm: const BgmPlan([
        BgmSegment(
          startUnit: 0,
          endUnit: 0,
          fit: BgmFit.loop,
          materials: [
            BgmMaterial(
                id: 9,
                name: '垫乐',
                durationMs: 30000,
                previewUrl: 'https://cdn/b.mp3')
          ],
        ),
      ]),
    );

    // S1 是人手选的原声，不许被「配乐覆盖就换人声」那条规则改掉；
    // S2 没设过，照旧走自动 → 纯人声
    final inputs = _inputsOf(b.calls);
    expect(inputs.where((i) => i == '/v/a.mp4'), hasLength(1),
        reason: 'S1 该用原混音（人选的）');
    expect(inputs.where((i) => i == stems.vocals), hasLength(1),
        reason: 'S2 没设过，自动那条路照旧换纯人声');
  });

  test('选了人声却没有分离轨：直接失败并说清怎么办，不悄悄退回原混音', () async {
    final b = _build();

    await expectLater(
      () => b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(s1Mode: MaterialAudioMode.vocals),
        replacedShots: const {(0, 0)},
      ),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          allOf(contains('U1 的 S1'), contains('重新分离')))),
    );
  });
}

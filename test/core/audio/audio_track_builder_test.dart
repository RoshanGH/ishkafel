import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// U1 = 0~4000（S1 0~2000、S2 2000~4000），U2 = 4000~6000（S1 整段）
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 4000,
        endMs: 6000,
        transcript: 'U2',
        shots: [Shot(startMs: 4000, endMs: 6000)],
      ),
    ];

const _bgmTrack = BgmMaterial(
    id: 9, name: '轻快垫乐', durationMs: 30000, previewUrl: 'https://cdn/b.mp3');

/// 每次 ffmpeg 调用的输入源（-i 后面第一个值）
List<String> _inputsOf(List<List<String>> calls) => [
      for (final a in calls)
        if (a.contains('-i')) a[a.indexOf('-i') + 1],
    ];

({AudioTrackBuilder builder, List<List<String>> calls}) _build() {
  final calls = <List<String>>[];
  final work = Directory.systemTemp.createTempSync('ishkafel_mix_');
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

void main() {
  group('没换配乐时一个字节都不动', () {
    test('全程用原混音，不碰分离出来的人声轨', () async {
      final b = _build();

      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        vocalsPath: '/v/vocals.wav',
      );

      expect(_inputsOf(b.calls), everyElement(isNot('/v/vocals.wav')),
          reason: '分离是有损的（实测残差 -27dB），没换配乐的地方没必要先损一道');
      expect(_inputsOf(b.calls).where((i) => i == '/v/a.mp4'), isNotEmpty);
    });
  });

  group('配乐覆盖到的段落才用纯人声', () {
    test('被盖住的镜头用人声轨，没盖住的仍用原混音', () async {
      final b = _build();

      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        vocalsPath: '/v/vocals.wav',
        // 只盖住全片第一个镜头（U1 的 S1，0~2000）
        bgm: const BgmPlan([
          BgmSegment(
              startUnit: 0, endUnit: 0, materials: [_bgmTrack], fit: BgmFit.cut),
        ]),
      );

      final inputs = _inputsOf(b.calls);
      expect(inputs.where((i) => i == '/v/vocals.wav'), hasLength(2),
          reason: 'U1 被盖住，它的两个镜头都要去掉原背景');
      expect(inputs.where((i) => i == '/v/a.mp4'), hasLength(1),
          reason: 'U2 没被盖住，照常用原混音——分离是有损的，'
              '没换配乐的地方没必要先损一道');
    });

    test('配乐按单元对齐，盖不到半个单元——整段要么全用人声轨要么全不用',
        () async {
      final b = _build();

      // 只盖住 U2
      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        vocalsPath: '/v/vocals.wav',
        bgm: const BgmPlan([
          BgmSegment(
              startUnit: 1, endUnit: 1, materials: [_bgmTrack], fit: BgmFit.cut),
        ]),
      );

      // U1 的两个镜头都用原混音，U2 那个用人声轨
      final trims = b.calls.where((a) => a.contains('-vn')).toList();
      expect(trims[0][trims[0].indexOf('-i') + 1], '/v/a.mp4');
      expect(trims[1][trims[1].indexOf('-i') + 1], '/v/a.mp4');
      expect(trims[2][trims[2].indexOf('-i') + 1], '/v/vocals.wav');
    });

    test('没有人声轨时退回原混音，不至于整条合不出来', () async {
      final b = _build();

      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        bgm: const BgmPlan([
          BgmSegment(
              startUnit: 0, endUnit: 0, materials: [_bgmTrack], fit: BgmFit.cut),
        ]),
      );

      expect(_inputsOf(b.calls).where((i) => i == '/v/a.mp4'), isNotEmpty);
    });
  });

  group('换过音色的单元', () {
    test('整段用配音，不去切原声', () async {
      final work = Directory.systemTemp.createTempSync('ishkafel_voice_');
      addTearDown(() => work.deleteSync(recursive: true));
      final voice = File('${work.path}/u0.mp3')..writeAsStringSync('v');
      final b = _build();

      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        voiceAudio: {0: voice.path},
      );

      final inputs = _inputsOf(b.calls);
      expect(inputs, contains(voice.path));
      // U1 的两个镜头都不该再去切原声，只剩 U2 那一段
      expect(inputs.where((i) => i == '/v/a.mp4'), hasLength(1));
    });

    test('配音文件不在了就退回原声——不能合出一段静音', () async {
      final b = _build();

      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        voiceAudio: const {0: '/不存在/u0.mp3'},
      );

      expect(_inputsOf(b.calls).where((i) => i == '/v/a.mp4'), hasLength(3));
    });
  });

  group('配乐叠上去', () {
    test('每段配乐混一次，位置按它覆盖的单元算', () async {
      final b = _build();

      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        vocalsPath: '/v/vocals.wav',
        bgm: const BgmPlan([
          BgmSegment(
              startUnit: 1, endUnit: 2, materials: [_bgmTrack], fit: BgmFit.loop),
        ]),
      );

      final mix = b.calls.firstWhere((a) => a.contains('-filter_complex'));
      // U2 起点 4000ms（endUnit 越界时夹到最后一个单元）
      expect(mix.join(' '), contains('adelay=4000|4000'));
      expect(mix.join(' '), contains('https://cdn/b.mp3'));
    });

    test('配乐没有可用地址时跳过这一段，其余照常', () async {
      final b = _build();

      await b.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        bgm: const BgmPlan([
          BgmSegment(
            startUnit: 0,
            endUnit: 0,
            materials: [BgmMaterial(
                id: 1, name: '过期的', durationMs: 1000, previewUrl: null)],
            fit: BgmFit.cut,
          ),
        ]),
      );

      expect(b.calls.where((a) => a.contains('-filter_complex')), isEmpty);
    });
  });
}

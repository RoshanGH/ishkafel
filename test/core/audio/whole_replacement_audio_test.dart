import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

const _bgm = BgmMaterial(
    id: 9, name: '垫乐', durationMs: 30000, previewUrl: 'https://cdn/b.mp3');

/// U1 = 0~4000、U2 = 4000~10000
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 4000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 4000,
        endMs: 10000,
        transcript: 'U2',
        shots: [Shot(startMs: 4000, endMs: 10000)],
      ),
    ];

({AudioTrackBuilder builder, List<List<String>> calls}) _build(Directory dir) {
  final calls = <List<String>>[];
  return (
    builder: AudioTrackBuilder(
      run: (binary, args) async {
        calls.add(args);
        await File(args.last).writeAsString('wav');
        return ProcessResult(1, 0, '', '');
      },
      workDir: dir,
      resolveBgm: (m) async => '/local/${m.id}.mp3',
    ),
    calls: calls,
  );
}

String _inputOf(List<String> args) => args[args.indexOf('-i') + 1];

void main() {
  late Directory temp;
  late String candidate;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('ishkafel_wra_');
    // 候选素材已经下到本地了——构建器只在文件真的存在时才用它
    candidate = '${temp.path}/71.mp4';
    File(candidate).writeAsStringSync('mp4');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  group('整体替换：这一段的声音来自候选素材', () {
    test('被整体替换的单元用候选的音轨，其余单元照旧用原片', () async {
      final env = _build(temp);

      await env.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        wholeAudio: {0: candidate},
      );

      final trims = env.calls.where((a) => a.contains('-vn')).toList();
      expect(_inputOf(trims[0]), candidate,
          reason: 'U1 整体替换了，说的话来自候选素材');
      expect(_inputOf(trims[1]), '/v/a.mp4', reason: 'U2 没换，还是原片');
    });

    test('候选的音轨整段取用，不裁不补——时长随候选', () async {
      final env = _build(temp);

      await env.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        wholeAudio: {0: candidate},
      );

      final first = env.calls.firstWhere((a) => a.contains('-vn'));
      expect(first.contains('-t'), isFalse,
          reason: '整体替换是「原样接上」，裁到原单元时长就不是整体替换了');
    });

    test('候选音频文件不在时退回原片，不至于合出一段静音', () async {
      final env = _build(temp);

      await env.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        wholeAudio: const {},
      );

      final trims = env.calls.where((a) => a.contains('-vn')).toList();
      expect(_inputOf(trims[0]), '/v/a.mp4');
    });
  });

  group('配乐位置按成片时间轴算', () {
    test('U1 变长之后，铺在 U2 上的配乐起点跟着后移', () async {
      final env = _build(temp);

      await env.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        vocalsPath: '/v/vocals.wav',
        // U1 的候选是 5.2 秒（原来 4 秒）
        wholeAudio: {0: candidate},
        wholeDurations: const {0: 5200},
        bgm: BgmPlan.empty
            .assign(startUnit: 1, endUnit: 1, materials: [_bgm], rangeMs: 6000),
      );

      final mix =
          env.calls.firstWhere((a) => a.contains('-filter_complex')).join(' ');
      expect(mix, contains('adelay=5200|5200'),
          reason: '按原片算是 4000，那样配乐会提前 1.2 秒响起来');
    });

    test('没有整体替换时还是原片的毫秒', () async {
      final env = _build(temp);

      await env.builder.build(
        sourcePath: '/v/a.mp4',
        units: _units(),
        vocalsPath: '/v/vocals.wav',
        bgm: BgmPlan.empty
            .assign(startUnit: 1, endUnit: 1, materials: [_bgm], rangeMs: 6000),
      );

      final mix =
          env.calls.firstWhere((a) => a.contains('-filter_complex')).join(' ');
      expect(mix, contains('adelay=4000|4000'));
    });
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_cache.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

const _bgm = BgmMaterial(
    id: 1, name: '尤克里里', durationMs: 30000, previewUrl: 'https://o/a.mp3');

List<SemanticUnit> _units() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 4000,
        transcript: '台词',
        shots: [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 4000),
        ],
      ),
    ];

ExportRunner _runner(
  Directory temp, {
  Future<String> Function(BgmMaterial)? resolveBgm,
}) =>
    ExportRunner(
      run: (binary, args) async {
        await File(args.last).writeAsString('out');
        return ProcessResult(1, 0, '', '');
      },
      workDir: Directory('${temp.path}/work'),
      fetchMaterial: (id) async => '/m/$id.mp4',
      resolveBgm: resolveBgm,
    );

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_exp_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('配乐取不到时导出直接失败，不产出一条少了垫乐的成片', () async {
    File('${temp.path}/vocals.wav').writeAsStringSync('v');
    final runner = _runner(temp, resolveBgm: (m) async {
      throw const BgmUnavailableException('地址已失效');
    });

    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      outputDir: Directory('${temp.path}/out'),
      bgm: BgmPlan.empty
          .assign(startShot: 0, endShot: 1, material: _bgm, shotRangeMs: 4000),
      vocalsPath: '${temp.path}/vocals.wav',
    );

    expect(results, isNotEmpty);
    expect(results.every((r) => r.failure != null), isTrue,
        reason: '预览可以降级——那时人还在编辑、听得出来；'
            '成片少一段配乐是静默的错，交付出去没人会发现');
    expect(results.first.failure, contains('尤克里里'),
        reason: '要说清是哪一条配乐');
    expect(results.first.path, isNull);
  });

  test('有配乐但没有分离出来的人声轨时也失败——新配乐会叠在原背景音上', () async {
    final runner = _runner(temp, resolveBgm: (m) async => '/local/1.mp3');

    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      outputDir: Directory('${temp.path}/out'),
      bgm: BgmPlan.empty
          .assign(startShot: 0, endShot: 1, material: _bgm, shotRangeMs: 4000),
      vocalsPath: null,
    );

    expect(results.every((r) => r.failure != null), isTrue,
        reason: '两首曲子一起响，而成片里听不出是「兜底」还是「本来就这样」');
    expect(results.first.failure, contains('人声'));
  });

  test('选了音色却没生成配音时失败——导出的会是原声，用户不会发现', () async {
    final runner = _runner(temp, resolveBgm: (m) async => '/local/1.mp3');

    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      outputDir: Directory('${temp.path}/out'),
      voices: VoicePlan.empty
          .assign([0], const VoiceRef(id: 'v1', name: '音色甲')),
      voiceAudio: const {},
    );

    expect(results.every((r) => r.failure != null), isTrue);
    expect(results.first.failure, contains('配音'));
  });

  test('配乐正常、人声轨在、配音齐了就照常导出', () async {
    final vocals = File('${temp.path}/vocals.wav')..writeAsStringSync('v');
    final voice = File('${temp.path}/u0.wav')..writeAsStringSync('a');
    final runner = _runner(temp, resolveBgm: (m) async => '/local/1.mp3');

    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      outputDir: Directory('${temp.path}/out'),
      bgm: BgmPlan.empty
          .assign(startShot: 0, endShot: 1, material: _bgm, shotRangeMs: 4000),
      vocalsPath: vocals.path,
      voices: VoicePlan.empty
          .assign([0], const VoiceRef(id: 'v1', name: '音色甲')),
      voiceAudio: {0: voice.path},
    );

    expect(results.every((r) => r.failure == null), isTrue,
        reason: '一切正常时不该被新的检查拦下来');
  });

  test('没有配乐方案时不检查人声轨——那条片子本来就用原声', () async {
    final runner = _runner(temp);

    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      outputDir: Directory('${temp.path}/out'),
      vocalsPath: null,
    );

    expect(results.every((r) => r.failure == null), isTrue);
  });
}

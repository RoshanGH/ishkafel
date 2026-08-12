import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_cache.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

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
  _blankTaskTests();
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
          .assign(startUnit: 0, endUnit: 1, materials: [_bgm], rangeMs: 4000),
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
          .assign(startUnit: 0, endUnit: 1, materials: [_bgm], rangeMs: 4000),
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
          .assign(startUnit: 0, endUnit: 1, materials: [_bgm], rangeMs: 4000),
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

  test('同一个单元既整体替换又换音色时中止——两边都想决定这段说什么', () async {
    final vocals = File('${temp.path}/vocals.wav')..writeAsStringSync('v');
    final voice = File('${temp.path}/u0.wav')..writeAsStringSync('a');
    final runner = _runner(temp, resolveBgm: (m) async => '/local/1.mp3');

    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [UnitReplacement.whole(const [77])],
      outputDir: Directory('${temp.path}/out'),
      vocalsPath: vocals.path,
      voices: VoicePlan.empty
          .assign([0], const VoiceRef(id: 'v1', name: '音色甲')),
      voiceAudio: {0: voice.path},
    );

    expect(results.every((r) => r.failure != null), isTrue,
        reason: '整体替换用候选自己的口播，换音色用 TTS 合成的口播，'
            '同一段两者矛盾；静默取其一正是用户反对的');
    expect(results.first.failure, contains('U1'));
  });

  test('整体替换在别的单元、换音色在这个单元，互不冲突', () async {
    final vocals = File('${temp.path}/vocals.wav')..writeAsStringSync('v');
    final voice = File('${temp.path}/u1.wav')..writeAsStringSync('a');
    final runner = _runner(temp, resolveBgm: (m) async => '/local/1.mp3');

    final results = await runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: [
        _units().first,
        SemanticUnit(
          index: 1,
          startMs: 4000,
          endMs: 8000,
          transcript: '第二句',
          shots: [Shot(startMs: 4000, endMs: 8000)],
        ),
      ],
      replacements: [UnitReplacement.whole(const [77])],
      outputDir: Directory('${temp.path}/out'),
      vocalsPath: vocals.path,
      voices: VoicePlan.empty
          .assign([1], const VoiceRef(id: 'v1', name: '音色甲')),
      voiceAudio: {1: voice.path},
    );

    expect(results.every((r) => r.failure == null), isTrue);
  });
}

/// 空白任务：没有原片，每个分子都要有素材才导得出来。
void _blankTaskTests() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_blank_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('有分子没挑素材时直接失败，并把是哪几个点出来', () async {
    final runner = _runner(temp);
    final results = await runner.exportAll(
      sourcePath: null, // 空白任务
      units: _units(),
      replacements: const [], // 一个都没挑
      outputDir: Directory('${temp.path}/out'),
    );

    expect(results.every((r) => r.failure != null), isTrue);
    // 「导出失败」三个字帮不了任何人——要说是哪个分子、下一步做什么
    expect(results.first.failure, contains('U1'));
    expect(results.first.failure, contains('删掉'));
    expect(results.first.failure, contains('挑满'));
  });

  test('不能拿黑场或静音顶上——一个文件都不该产出', () async {
    final out = Directory('${temp.path}/out');
    final runner = _runner(temp);
    await runner.exportAll(
      sourcePath: null,
      units: _units(),
      replacements: const [],
      outputDir: out,
    );
    expect(out.existsSync() && out.listSync().isNotEmpty, isFalse);
  });
}

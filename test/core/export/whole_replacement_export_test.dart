import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

List<SemanticUnit> _units() => [
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

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_wre_'));
  tearDown(() => temp.deleteSync(recursive: true));

  ({ExportRunner runner, List<List<String>> calls}) make() {
    final calls = <List<String>>[];
    return (
      runner: ExportRunner(
        run: (binary, args) async {
          calls.add(args);
          await File(args.last).writeAsString('out');
          return ProcessResult(1, 0, '', '');
        },
        workDir: Directory('${temp.path}/work'),
        fetchMaterial: (id) async {
          final f = File('${temp.path}/$id.mp4')..writeAsStringSync('mp4');
          return f.path;
        },
        // 候选是 5.2 秒（原单元 4.0 秒）
        probeDurationMs: (path) async => 5200,
      ),
      calls: calls,
    );
  }

  test('整体替换的画面原样接上——不变速、不裁、不冻帧', () async {
    final env = make();

    await env.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [UnitReplacement.whole(const [71])],
      outputDir: Directory('${temp.path}/out'),
    );

    final clip = env.calls.firstWhere((a) =>
        a.contains('-i') && a[a.indexOf('-i') + 1].endsWith('71.mp4'));
    final vf = clip[clip.indexOf('-vf') + 1];

    expect(vf, isNot(contains('setpts')), reason: '整体替换不变速');
    expect(vf, isNot(contains('tpad')), reason: '整体替换不冻帧补齐');
    expect(clip.contains('-frames:v'), isFalse,
        reason: '锁死帧数就等于裁到原单元时长，那不是整体替换');
  });

  test('镜头替换仍然变速对齐', () async {
    final env = make();

    await env.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.perShot(const {
          0: [71]
        })
      ],
      outputDir: Directory('${temp.path}/out'),
    );

    final clip = env.calls.firstWhere((a) =>
        a.contains('-i') && a[a.indexOf('-i') + 1].endsWith('71.mp4'));

    expect(clip[clip.indexOf('-vf') + 1], contains('setpts=PTS/1.3'),
        reason: '5.2 秒填 4.0 秒的坑位');
  });

  test('整体替换时每条变体各合各的声音——候选不同、时长也不同', () async {
    final env = make();

    await env.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [UnitReplacement.whole(const [71, 72])],
      outputDir: Directory('${temp.path}/out'),
    );

    final voiceMixes =
        env.calls.where((a) => a.last.endsWith('mix_voice.wav')).length;
    expect(voiceMixes, 2, reason: '两条变体的声音不一样，不能共用一条');
  });
}

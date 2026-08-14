import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 一个单元、两个 3 秒镜头
List<SemanticUnit> _units() => [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 6000,
        transcript: '台词',
        shots: [
          Shot(startMs: 0, endMs: 3000),
          Shot(startMs: 3000, endMs: 6000),
        ],
      ),
    ];

List<UnitReplacement> _perShot(Map<int, int> shotToCandidate) => [
      UnitReplacement.perShot({
        for (final e in shotToCandidate.entries) e.key: [e.value],
      }),
    ];

({ExportRunner runner, List<String> ran}) _runner(
  Directory temp, {
  required Map<int, int> durations,
}) {
  final ran = <String>[];
  return (
    runner: ExportRunner(
      run: (binary, args) async {
        ran.add(args.join(' '));
        await File(args.last).writeAsString('out');
        return ProcessResult(1, 0, '', '');
      },
      workDir: Directory('${temp.path}/work'),
      fetchMaterial: (id) async => '/m/$id.mp4',
      probeDurationMs: (path) async {
        final id = int.parse(RegExp(r'(\d+)').firstMatch(path)!.group(1)!);
        return durations[id];
      },
    ),
    ran: ran,
  );
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('ishkafel_spd_'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<List<ExportOutcome>> run(
    ({ExportRunner runner, List<String> ran}) env, {
    required Map<int, int> picks,
  }) =>
      env.runner.exportAll(
        sourcePath: '/v/a.mp4',
        units: _units(),
        replacements: _perShot(picks),
        outputDir: Directory('${temp.path}/out'),
      );

  test('候选在范围内时按倍率变速', () async {
    final env = _runner(temp, durations: {77: 4500});

    final results = await run(env, picks: {0: 77});

    expect(results.single.failure, isNull);
    expect(env.ran.where((c) => c.contains('setpts=PTS/1.5')), hasLength(1),
        reason: '4.5 秒素材填 3 秒坑位 = 加速 1.5 倍');
  });

  test('倍率不设上限：3 秒坑位塞 10 秒素材照常按 3.3 倍导出', () async {
    // 预览渲染的就是真实倍率的切片——用户在预览里看过并接受了，
    // 软件不该再替他做审美判断。原来这里有一道 0.8×~2.0× 的闸，已拆掉
    final env = _runner(temp, durations: {77: 10000});

    final results = await run(env, picks: {0: 77});

    expect(results.single.failure, isNull);
    expect(env.ran.where((c) => c.contains('setpts=PTS/3.33')), hasLength(1),
        reason: '10 秒素材填 3 秒坑位 = 加速 3.33 倍，如实变速');
  });

  test('放慢也不设下限：1 秒素材填 3 秒坑位按 0.33 倍放慢', () async {
    final env = _runner(temp, durations: {77: 1000});

    final results = await run(env, picks: {0: 77});

    expect(results.single.failure, isNull);
    expect(env.ran.where((c) => c.contains('setpts=PTS/0.33')), hasLength(1));
  });

  test('探测不出候选时长时不猜倍率，退回裁/冻帧照常导出', () async {
    final env = _runner(temp, durations: const {});

    final results = await run(env, picks: {0: 77});

    expect(results.single.failure, isNull);
    expect(env.ran.where((c) => c.contains('setpts')), isEmpty);
  });

  test('没有替换时不做任何变速检查', () async {
    final env = _runner(temp, durations: const {});

    final results = await env.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: const [],
      outputDir: Directory('${temp.path}/out'),
    );

    expect(results.single.failure, isNull);
  });
}

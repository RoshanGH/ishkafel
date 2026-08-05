import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 假 ffmpeg：记录每一次调用，并按需要造出输出文件
class _Ffmpeg {
  final calls = <List<String>>[];

  /// 命中这个片段的调用就当失败（模拟某一步挂掉）
  final String? failOn;

  _Ffmpeg({this.failOn});

  Future<ProcessResult> call(String bin, List<String> args) async {
    calls.add(args);
    if (failOn != null && args.join(' ').contains(failOn!)) {
      return ProcessResult(1, 1, '', '第一行\n第二行\nffmpeg 报的真正原因');
    }
    // 输出路径是最后一个参数，造个空文件让后续步骤有东西可读
    File(args.last).writeAsStringSync('x');
    return ProcessResult(1, 0, '', '');
  }

  /// 有多少次调用是在做这件事
  int countWhere(bool Function(String joined) test) =>
      calls.where((a) => test(a.join(' '))).length;
}

List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 2000,
        transcript: 'U1',
        shots: [Shot(startMs: 0, endMs: 2000)],
      ),
      SemanticUnit(
        index: 1,
        startMs: 2000,
        endMs: 5000,
        transcript: 'U2',
        shots: [Shot(startMs: 2000, endMs: 5000)],
      ),
    ];

({ExportRunner runner, _Ffmpeg ffmpeg, Directory out, List<int> fetched})
    _build({String? failOn}) {
  final ffmpeg = _Ffmpeg(failOn: failOn);
  final work = Directory.systemTemp.createTempSync('ishkafel_exp_work_');
  final out = Directory.systemTemp.createTempSync('ishkafel_exp_out_');
  addTearDown(() {
    work.deleteSync(recursive: true);
    out.deleteSync(recursive: true);
  });
  final fetched = <int>[];
  return (
    runner: ExportRunner(
      run: ffmpeg.call,
      workDir: work,
      fetchMaterial: (id) async {
        fetched.add(id);
        final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
        return f.path;
      },
    ),
    ffmpeg: ffmpeg,
    out: out,
    fetched: fetched,
  );
}

void main() {
  test('两个候选 = 两条成片，各自落到输出目录', () async {
    final b = _build();

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
      outputDir: b.out,
    );

    expect(results.map((r) => r.ok), [true, true]);
    expect(results.map((r) => r.path!.split('/').last), ['变体1.mp4', '变体2.mp4']);
    expect(b.fetched, [11, 12]);
  });

  test('声音只做一遍——所有组合的声音完全相同', () async {
    final b = _build();

    await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [11, 12, 13]),
        UnitReplacement.keepOriginal(),
      ],
      outputDir: b.out,
    );

    // 每个单元一段原声，共两段；三条组合不该把它们各做三遍
    // （声音由共用的 AudioTrackBuilder 合成，产物叫 mix_u*）
    expect(b.ffmpeg.countWhere((a) => a.contains('mix_u')), 2,
        reason: '声音是变量之外的东西，三条组合各做一遍纯属浪费');
  });

  test('同一段原片画面只切一遍——它会在多条组合里重复出现', () async {
    final b = _build();

    await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [11, 12, 13]),
        UnitReplacement.keepOriginal(),
      ],
      outputDir: b.out,
    );

    // U2 的原片画面在三条组合里都出现，只该切一次
    expect(b.ffmpeg.countWhere((a) => a.contains('clip_2000_5000_null')), 1);
  });

  test('一条失败不拖累其余：其余照常导出，失败那条带原因', () async {
    // 第二条组合用的是候选 12
    final b = _build(failOn: 'm12.mp4');

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
      outputDir: b.out,
    );

    expect(results.first.ok, isTrue);
    expect(results.last.ok, isFalse);
    expect(results.last.failure, contains('ffmpeg 报的真正原因'),
        reason: 'ffmpeg 的 stderr 动辄几百行，真正的原因总在末尾');
  });

  test('声音挂了就没有哪条能成，如实给每一条同一个原因', () async {
    final b = _build(failOn: 'mix_u0');

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
      outputDir: b.out,
    );

    expect(results, hasLength(2));
    expect(results.every((r) => !r.ok), isTrue);
    expect(results.first.failure, contains('声音合成失败'));
  });

  test('进度报到每一条，最后落在完成', () async {
    final b = _build();
    final progress = <(int, int, String)>[];

    await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.whole(const [11, 12]),
        UnitReplacement.keepOriginal(),
      ],
      outputDir: b.out,
      onProgress: (d, t, w) => progress.add((d, t, w)),
    );

    expect(progress.first.$3, '准备声音');
    expect(progress.last, (2, 2, '完成'));
  });

  test('一条都没选也要导出原片本身，而不是空手而归', () async {
    final b = _build();

    final results = await b.runner.exportAll(
      sourcePath: '/v/a.mp4',
      units: _units(),
      replacements: [
        UnitReplacement.keepOriginal(),
        UnitReplacement.keepOriginal(),
      ],
      outputDir: b.out,
    );

    expect(results, hasLength(1));
    expect(results.single.ok, isTrue);
  });
}

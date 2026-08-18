import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/export/export_runner.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_rasterizer.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';
import 'package:path/path.dart' as p;

/// 假渲染器：不起 osascript，记录渲了什么并写个假 PNG
class _FakeRasterizer implements SubtitleRasterizer {
  final rendered = <String>[];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<List<SubtitleOverlayImage>> rasterize({
    required List<SubtitleLine> lines,
    required int width,
    required int height,
    required SubtitleStyle style,
    required Directory outDir,
  }) async {
    outDir.createSync(recursive: true);
    return [
      for (final (i, line) in lines.indexed)
        () {
          rendered.add(line.text);
          final path = p.join(outDir.path, 'fake_$i.png');
          File(path).writeAsStringSync('png');
          return SubtitleOverlayImage(
              pngPath: path, startMs: line.startMs, endMs: line.endMs);
        }(),
    ];
  }
}

/// 镜头替换保留台词字幕：换掉画面后，原片烧在像素里的字幕跟着没了——
/// 导出时用任务的句级转写渲成透明图，用内建 overlay 滤镜叠到替换切片上。
void main() {
  final calls = <List<String>>[];

  Future<ProcessResult> ffmpeg(String bin, List<String> args) async {
    calls.add(args);
    File(args.last).writeAsStringSync('x');
    return ProcessResult(1, 0, '', '');
  }

  List<SemanticUnit> units() => const [
        SemanticUnit(
          index: 0,
          startMs: 0,
          endMs: 5000,
          transcript: '第一句 第二句',
          shots: [Shot(startMs: 0, endMs: 2000), Shot(startMs: 2000, endMs: 5000)],
        ),
      ];

  Future<_FakeRasterizer> export({required List<AsrSentence> sentences}) async {
    calls.clear();
    final rasterizer = _FakeRasterizer();
    final work = Directory.systemTemp.createTempSync('ishkafel_sub_work_');
    final out = Directory.systemTemp.createTempSync('ishkafel_sub_out_');
    addTearDown(() {
      if (work.existsSync()) work.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });
    final runner = ExportRunner(
      run: ffmpeg,
      workDir: work,
      rasterizer: rasterizer,
      fetchMaterial: (id) async {
        final f = File('${work.path}/m$id.mp4')..writeAsStringSync('m');
        return f.path;
      },
    );
    final results = await runner.exportAll(
      sourcePath: '/v/src.mp4',
      units: units(),
      replacements: [
        // S2 换成候选 9，S1 保留原片
        UnitReplacement.perShot(const {1: [9]}),
      ],
      outputDir: out,
      subtitleSentences: sentences,
    );
    expect(results.single.ok, isTrue, reason: results.single.failure ?? '');
    return rasterizer;
  }

  String joined(List<String> args) => args.join(' ');

  test('被替换的镜头叠上这段台词的字幕图，保留原片的镜头不动', () async {
    final rasterizer = await export(sentences: const [
      AsrSentence(startMs: 0, endMs: 2000, text: '第一句'),
      AsrSentence(startMs: 2000, endMs: 5000, text: '第二句'),
    ]);

    // 只渲染了坑位（2s–5s）里的那句；第一句归保留原片的镜头管
    expect(rasterizer.rendered, ['第二句']);

    // 替换切片（候选 m9）那一条命令带 overlay，字幕图是第二路输入
    final fit = calls.where((a) => joined(a).contains('m9.mp4')).single;
    final fc = fit[fit.indexOf('-filter_complex') + 1];
    expect(fc, contains("overlay=0:0:enable='between(t,0.000,3.000)'"));
    expect(joined(fit), contains('fake_0.png'));

    // 原片切片那一条不叠字幕——它自带的字幕还在画面里
    final trim = calls.where((a) => joined(a).contains('/v/src.mp4')).first;
    expect(joined(trim), isNot(contains('overlay')));
  });

  test('没有转写（老任务/空白任务）：照常导出，替换切片不带字幕', () async {
    final rasterizer = await export(sentences: const []);
    expect(rasterizer.rendered, isEmpty);
    final fit = calls.where((a) => joined(a).contains('m9.mp4')).single;
    expect(joined(fit), isNot(contains('overlay')));
  });
}

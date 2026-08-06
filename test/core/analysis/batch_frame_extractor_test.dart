import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/batch_frame_extractor.dart';
import 'package:path/path.dart' as p;

Directory _temp() {
  final dir = Directory.systemTemp.createTempSync('ishkafel_batch_');
  addTearDown(() => dir.deleteSync(recursive: true));
  return dir;
}

/// 假 ffmpeg：按 [emit] 张往输出目录里写图
BatchFrameExtractor _extractor(
  Directory dir, {
  required int emit,
  int exitCode = 0,
  List<List<String>>? calls,
}) =>
    BatchFrameExtractor(
      run: (binary, args) async {
        calls?.add(args);
        if (exitCode == 0) {
          final pattern = args.last;
          for (var i = 1; i <= emit; i++) {
            File(pattern.replaceAll(
                    '%03d', i.toString().padLeft(3, '0')))
                .writeAsStringSync('jpg$i');
          }
        }
        return ProcessResult(1, exitCode, '', 'boom');
      },
    );

void main() {
  test('一次调用把要的帧全抽出来，按时间点取得到各自的图', () async {
    final dir = _temp();
    final calls = <List<String>>[];
    final result = await _extractor(dir, emit: 3, calls: calls).extract(
      videoPath: '/v/a.mp4',
      requestedMs: const [2000, 100, 1000],
      fps: 30,
      outDir: dir,
      height: 512,
    );

    expect(result, isNotNull);
    expect(p.basename(result![100]!), 'batch_001.jpg');
    expect(p.basename(result[1000]!), 'batch_002.jpg');
    expect(p.basename(result[2000]!), 'batch_003.jpg');
    expect(calls, hasLength(1), reason: '批量的意义就在于只跑一次');
    expect(calls.single.join(' '), contains('select='));
  });

  test('吐出的图少于计划时整批作废——错位比慢严重得多', () async {
    final dir = _temp();

    final result = await _extractor(dir, emit: 2).extract(
      videoPath: '/v/a.mp4',
      requestedMs: const [0, 1000, 2000],
      fps: 30,
      outDir: dir,
      height: 512,
    );

    expect(result, isNull,
        reason: '少一张，后面全体前移一位，标签会安静地落到别的镜头上；'
            '返回 null 让调用方退回逐帧抽');
  });

  test('多吐几张也作废——对不上就是对不上', () async {
    final dir = _temp();

    final result = await _extractor(dir, emit: 5).extract(
      videoPath: '/v/a.mp4',
      requestedMs: const [0, 1000, 2000],
      fps: 30,
      outDir: dir,
      height: 512,
    );

    expect(result, isNull);
  });

  test('ffmpeg 失败时返回 null，不抛——调用方要能退回逐帧', () async {
    final dir = _temp();

    final result = await _extractor(dir, emit: 0, exitCode: 1).extract(
      videoPath: '/v/a.mp4',
      requestedMs: const [0],
      fps: 30,
      outDir: dir,
      height: 512,
    );

    expect(result, isNull);
  });

  test('帧率不可信时压根不跑 ffmpeg', () async {
    final dir = _temp();
    final calls = <List<String>>[];

    final result = await _extractor(dir, emit: 0, calls: calls).extract(
      videoPath: '/v/a.mp4',
      requestedMs: const [1000],
      fps: 0,
      outDir: dir,
      height: 512,
    );

    expect(result, isNull);
    expect(calls, isEmpty);
  });
}

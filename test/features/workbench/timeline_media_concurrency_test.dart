import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';

void main() {
  group('时间线辅助素材的构建并发度（进页面后两条轨空白的时长直接由它决定）', () {
    late Directory workDir;

    setUp(() => workDir = Directory.systemTemp.createTempSync('tl_conc_'));
    tearDown(() => workDir.deleteSync(recursive: true));

    test('抽帧并发进行，而不是十几次 ffmpeg 一个接一个排队', () async {
      var inFlight = 0;
      var peakInFlight = 0;

      final thumbnails = ThumbnailService(run: (_, args) async {
        inFlight++;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        // 让出事件循环，模拟真实子进程的等待
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        inFlight--;
        return ProcessResult(1, 0, '', '');
      });
      final audio = AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      });

      final media = await TimelineMediaBuilder(
        thumbnails: thumbnails,
        audio: audio,
      ).build(
        videoPath: '/tmp/x.mp4',
        taskId: 'concurrency',
        durationMs: 96000,
        workDir: workDir,
      );

      expect(peakInFlight, greaterThan(1),
          reason: '串行抽帧下峰值并发恒为 1；真机实测 14 次串行要 2.04 秒，'
              '这段时间里胶片条与波形轨都是空白');
      expect(media.thumbPaths, hasLength(14),
          reason: '并发不能把任何一张漏掉');
    });

    test('并发有上限，不会同时拉起十几个 ffmpeg 把机器打满', () async {
      var inFlight = 0;
      var peakInFlight = 0;

      final thumbnails = ThumbnailService(run: (_, args) async {
        inFlight++;
        if (inFlight > peakInFlight) peakInFlight = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        inFlight--;
        return ProcessResult(1, 0, '', '');
      });
      final audio = AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      });

      await TimelineMediaBuilder(thumbnails: thumbnails, audio: audio).build(
        videoPath: '/tmp/x.mp4',
        taskId: 'cap',
        durationMs: 96000,
        workDir: workDir,
      );

      expect(peakInFlight, lessThanOrEqualTo(4),
          reason: '视频解码是重活，无上限并发会把 CPU 打满、拖慢正在播放的预览');
    });

    test('顺序与时间对应关系不能被并发打乱', () async {
      final thumbnails = ThumbnailService(run: (_, args) async {
        // 故意让靠后的任务先完成，放大乱序风险
        final idx = int.parse(RegExp(r'_tl_(\d+)\.jpg').firstMatch(args.last)![1]!);
        await Future<void>.delayed(Duration(milliseconds: (14 - idx) * 2));
        await File(args.last).writeAsBytes(List<int>.filled(600, 1));
        return ProcessResult(1, 0, '', '');
      });
      final audio = AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      });

      final media = await TimelineMediaBuilder(
        thumbnails: thumbnails,
        audio: audio,
      ).build(
        videoPath: '/tmp/x.mp4',
        taskId: 'order',
        durationMs: 96000,
        workDir: workDir,
      );

      for (var i = 0; i < media.thumbPaths.length; i++) {
        expect(media.thumbPaths[i], endsWith('_tl_$i.jpg'),
            reason: '胶片条按时间顺序平铺，顺序错乱会让用户看到与时间对不上的画面');
      }
    });
  });

  group('包络采样密度随片长增长（固定桶数会让长素材的波形失去作用）', () {
    test('每秒约 100 个样本', () {
      expect(TimelineMediaBuilder.envelopeBucketsFor(96000), 9600);
      expect(TimelineMediaBuilder.envelopeBucketsFor(300000), 30000);
    });

    test('极短素材有下限，超长素材有上限（内存兜底）', () {
      expect(TimelineMediaBuilder.envelopeBucketsFor(500), 240,
          reason: '半秒素材也要有足够柱子铺满视口');
      expect(TimelineMediaBuilder.envelopeBucketsFor(3600000), 60000,
          reason: '一小时素材不能无限增长；60000 个 double 约 480KB 已是上限');
    });
  });
}

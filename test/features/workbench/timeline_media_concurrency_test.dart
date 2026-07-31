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
        thumbCount: 14,
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
        thumbCount: 14,
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
        thumbCount: 14,
        workDir: workDir,
      );

      for (var i = 0; i < media.thumbPaths.length; i++) {
        expect(media.thumbPaths[i], endsWith('_tl_$i.jpg'),
            reason: '胶片条按时间顺序平铺，顺序错乱会让用户看到与时间对不上的画面');
      }
    });
  });

  group('抽帧密度随片长增长（固定张数会让胶片条退化成彩色噪声）', () {
    test('每 3 秒一张', () {
      expect(TimelineMediaBuilder.thumbCountFor(96000), 32,
          reason: '96 秒按每 3 秒一张是 32 张，正好落在上限');
      expect(TimelineMediaBuilder.thumbCountFor(60000), 20);
    });

    test('极短素材有下限，长素材有上限（控制首次加载耗时）', () {
      expect(TimelineMediaBuilder.thumbCountFor(5000), 14);
      expect(TimelineMediaBuilder.thumbCountFor(300000), 32,
          reason: '5 分钟素材封顶 32 张；再多会让进页面等待明显变长，'
              '真正的解法是随缩放动态补帧（已记入待办）');
    });
  });

  group('抽帧缓存不能跨张数复用（时间点会对不上）', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tl_cache_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('张数变化后不复用旧缓存，重新按新时间点抽帧', () async {
      final calls = <double>[];
      ThumbnailService probe() => ThumbnailService(run: (_, args) async {
            calls.add(double.parse(args[args.indexOf('-ss') + 1]));
            await File(args.last).writeAsBytes(List<int>.filled(600, 1));
            return ProcessResult(1, 0, '', '');
          });
      final audio = AudioExtractor(run: (_, args) async {
        await File(args.last).writeAsBytes(List<int>.filled(64, 0));
        return ProcessResult(1, 0, '', '');
      });

      // 先按 4 张抽一遍（模拟旧版本留下的缓存）
      await TimelineMediaBuilder(thumbnails: probe(), audio: audio).build(
        videoPath: '/tmp/x.mp4',
        taskId: 'cache',
        durationMs: 40000,
        thumbCount: 4,
        workDir: dir,
      );

      // 再按 8 张抽：若缓存按下标复用，前 4 张会沿用「4 张布局」的时间点，
      // 胶片条就与时间对不上了
      calls.clear();
      final media = await TimelineMediaBuilder(thumbnails: probe(), audio: audio)
          .build(
        videoPath: '/tmp/x.mp4',
        taskId: 'cache',
        durationMs: 40000,
        thumbCount: 8,
        workDir: dir,
      );

      expect(media.thumbPaths, hasLength(8));
      expect(calls, hasLength(8),
          reason: '张数变了就必须整条重抽；复用旧下标的缓存会让前几张停留在'
              '按旧张数算出的时间点上');
      calls.sort();
      expect(calls.first, closeTo(40000 * 0.5 / 8 / 1000, 0.001),
          reason: '首张应落在「8 张布局」的第一格中点');
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

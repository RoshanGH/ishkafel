import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/audio_extractor.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/features/workbench/timeline_media_builder.dart';

/// 把 16 位有符号采样编码为小端 PCM 字节
Uint8List _pcm16Bytes(List<int> samples) {
  final bytes = Int16List.fromList(samples).buffer.asUint8List();
  return Uint8List.fromList(bytes);
}

void main() {
  group('TimelineMediaBuilder.computeEnvelope（纯函数）', () {
    test('返回定长数组，长度恒等于 buckets', () {
      final envelope =
          TimelineMediaBuilder.computeEnvelope([1, 2, 3, 4, 5, 6], 10);
      expect(envelope.length, 10);
    });

    test('响亮分段 bucket 高于静音分段，且峰值归一化为 1.0', () {
      // 8 个采样均分 4 个 bucket：[100,100] [0,0] [50,50] [0,0]
      final envelope =
          TimelineMediaBuilder.computeEnvelope([100, 100, 0, 0, 50, 50, 0, 0], 4);
      expect(envelope[0], 1.0); // 峰值 bucket 归一化到 1.0
      expect(envelope[1], 0.0); // 静音 bucket
      expect(envelope[2], 0.5); // 响度为峰值一半
      expect(envelope[3], 0.0); // 静音 bucket
    });

    test('全静音输入（最大值为 0）返回全 0', () {
      final envelope = TimelineMediaBuilder.computeEnvelope([0, 0, 0, 0], 4);
      expect(envelope, [0.0, 0.0, 0.0, 0.0]);
    });

    test('空采样返回全 0，长度仍为 buckets', () {
      final envelope = TimelineMediaBuilder.computeEnvelope([], 5);
      expect(envelope, [0.0, 0.0, 0.0, 0.0, 0.0]);
    });
  });

  group('TimelineMediaBuilder.build', () {
    late Directory workDir;

    setUp(() async {
      workDir = await Directory.systemTemp.createTemp('ishkafel_tl_media_');
    });

    tearDown(() async {
      if (await workDir.exists()) {
        await workDir.delete(recursive: true);
      }
    });

    /// 构造记录调用参数、且写出假文件的抽帧服务
    ({ThumbnailService service, List<List<String>> calls}) fakeThumbnails({
      bool Function(String outPath)? shouldFail,
    }) {
      final calls = <List<String>>[];
      final service = ThumbnailService(run: (exe, args) async {
        calls.add(args);
        final outPath = args.last;
        if (shouldFail != null && shouldFail(outPath)) {
          return ProcessResult(1, 1, '', '模拟抽帧失败');
        }
        await File(outPath).writeAsBytes([0]);
        return ProcessResult(1, 0, '', '');
      });
      return (service: service, calls: calls);
    }

    /// 构造记录调用参数、写出假 PCM 的音频提取服务
    ({AudioExtractor service, List<List<String>> calls}) fakeAudio({
      List<int> samples = const [100, -100, 100, -100],
      bool fail = false,
    }) {
      final calls = <List<String>>[];
      final service = AudioExtractor(run: (exe, args) async {
        calls.add(args);
        if (fail) {
          return ProcessResult(1, 1, '', '模拟音频提取失败');
        }
        final outPcmPath = args.last;
        await File(outPcmPath).writeAsBytes(_pcm16Bytes(samples));
        return ProcessResult(1, 0, '', '');
      });
      return (service: service, calls: calls);
    }

    test('等间隔取 thumbCount 个时间点并写出对应缩略图路径', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final media = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't1',
        durationMs: 9000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );

      expect(media.thumbPaths, [
        '${workDir.path}/t1_tl_0.jpg',
        '${workDir.path}/t1_tl_1.jpg',
        '${workDir.path}/t1_tl_2.jpg',
      ]);
      // atSeconds = durationMs * (i+0.5) / thumbCount / 1000.0 → 1.5, 4.5, 7.5（等间隔 3s）
      final atSecondsSeq = thumbs.calls.map((args) {
        final idx = args.indexOf('-ss');
        return double.parse(args[idx + 1]);
      }).toList();
      expect(atSecondsSeq, [1.5, 4.5, 7.5]);
      expect(media.waveEnvelope.length, 8);
    });

    test('缩略图文件已存在则跳过抽帧（缓存命中）', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't2',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );
      expect(thumbs.calls.length, 3);

      // 第二次调用：目标文件已存在，不应再触发 ffmpeg 抽帧
      await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't2',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );
      expect(thumbs.calls.length, 3);
    });

    test('PCM 文件已存在则跳过音频提取（缓存命中）', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final first = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't3',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 8,
      );
      expect(audio.calls.length, 1);

      final second = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't3',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 8,
      );
      expect(audio.calls.length, 1); // 未再次调用
      expect(second.waveEnvelope, first.waveEnvelope);
    });

    test('部分抽帧失败：跳过失败项，返回可用的部分 thumbPaths，不抛异常', () async {
      final thumbs =
          fakeThumbnails(shouldFail: (outPath) => outPath.contains('_tl_1.jpg'));
      final audio = fakeAudio();
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final media = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't4',
        durationMs: 9000,
        workDir: workDir,
        thumbCount: 3,
        waveBuckets: 8,
      );

      expect(media.thumbPaths, [
        '${workDir.path}/t4_tl_0.jpg',
        '${workDir.path}/t4_tl_2.jpg',
      ]);
    });

    test('音频提取失败：包络返回全 0，不抛异常，缩略图不受影响', () async {
      final thumbs = fakeThumbnails();
      final audio = fakeAudio(fail: true);
      final builder =
          TimelineMediaBuilder(thumbnails: thumbs.service, audio: audio.service);

      final media = await builder.build(
        videoPath: '/v/a.mp4',
        taskId: 't5',
        durationMs: 6000,
        workDir: workDir,
        thumbCount: 2,
        waveBuckets: 6,
      );

      expect(media.thumbPaths.length, 2);
      expect(media.waveEnvelope, List.filled(6, 0.0));
    });
  });
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';

void main() {
  test('buildArgs 生成正确的 ffmpeg 抽帧参数（-ss 前置快速 seek）', () {
    expect(
      ThumbnailService.buildArgs(
          videoPath: '/v/a.mp4', outPath: '/o/c.jpg', atSeconds: 1.5, height: 480),
      [
        '-y',
        '-loglevel', 'error',
        '-ss', '1.5',
        '-i', '/v/a.mp4',
        '-frames:v', '1',
        '-vf', 'scale=-2:480',
        '-q:v', '3',
        '/o/c.jpg',
      ],
    );
  });

  test('extractCover 成功返回输出路径', () async {
    final service = ThumbnailService(
        run: (_, _) async => ProcessResult(1, 0, '', ''));
    final out = await service.extractCover(
        videoPath: '/v/a.mp4', outPath: '/o/c.jpg');
    expect(out, '/o/c.jpg');
  });

  test('ffmpeg 失败抛 FfmpegException', () async {
    final service = ThumbnailService(
        run: (_, _) async => ProcessResult(1, 1, '', 'Invalid data'));
    expect(
      () => service.extractCover(videoPath: '/v/a.mp4', outPath: '/o/c.jpg'),
      throwsA(isA<FfmpegException>()),
    );
  });
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/ffprobe_service.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

const okJson = {
  'streams': [
    {'codec_type': 'video', 'width': 1080, 'height': 1920, 'r_frame_rate': '30/1'},
  ],
  'format': {'duration': '96.2', 'size': '100'},
};

ProcessResult okResult() => ProcessResult(1, 0, jsonEncode(okJson), '');

void main() {
  test('buildArgs 生成正确的 ffprobe 参数', () {
    expect(FfprobeService.buildArgs('/v/a.mp4'), [
      '-v', 'error',
      '-show_streams', '-show_format',
      '-print_format', 'json',
      '/v/a.mp4',
    ]);
  });

  test('probe 成功解析 VideoInfo', () async {
    late String usedExe;
    late List<String> usedArgs;
    final service = FfprobeService(run: (exe, args) async {
      usedExe = exe;
      usedArgs = args;
      return okResult();
    });
    final info = await service.probe('/v/a.mp4');
    expect(usedExe, 'ffprobe');
    expect(usedArgs.last, '/v/a.mp4');
    expect(info.width, 1080);
    expect(info.duration.inMilliseconds, 96200);
  });

  test('ffprobe 非零退出码抛 FfmpegException 且带 stderr', () async {
    final service = FfprobeService(
        run: (_, _) async => ProcessResult(1, 1, '', 'No such file'));
    expect(
      () => service.probe('/v/missing.mp4'),
      throwsA(isA<FfmpegException>()
          .having((e) => e.message, 'message', contains('No such file'))),
    );
  });
}

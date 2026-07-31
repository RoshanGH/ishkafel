import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_tools_locator.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

void main() {
  group('ResolvingProcessRunner', () {
    test('裸名 ffmpeg 先解析成绝对路径再启动子进程', () async {
      final invoked = <String>[];
      final runner = ResolvingProcessRunner(
        locator: MediaToolsLocator(
          probe: (path) => path.startsWith('/opt/homebrew/bin/'),
          lookupOnPath: (_) => null,
        ),
        invoke: (executable, args) async {
          invoked.add(executable);
          return ProcessResult(1, 0, '', '');
        },
      );

      final result = await runner('ffmpeg', const ['-version']);

      expect(result.exitCode, 0);
      expect(invoked, ['/opt/homebrew/bin/ffmpeg']);
    });

    test('工具缺失时抛中文提示的 FfmpegException，且不启动任何子进程', () async {
      final runner = ResolvingProcessRunner(
        locator:
            MediaToolsLocator(probe: (_) => false, lookupOnPath: (_) => null),
        invoke: (_, _) async => fail('工具缺失时不应启动子进程'),
      );

      await expectLater(
        runner('ffprobe', const []),
        throwsA(isA<FfmpegException>().having(
            (e) => e.message, 'message', allOf(contains('ffprobe'), contains('未找到')))),
      );
    });

    test('绝对路径调用不再二次解析，直接透传', () async {
      final invoked = <String>[];
      final runner = ResolvingProcessRunner(
        locator: MediaToolsLocator(
          probe: (_) => fail('绝对路径无需解析'),
          lookupOnPath: (_) => fail('绝对路径无需解析'),
        ),
        invoke: (executable, args) async {
          invoked.add(executable);
          return ProcessResult(1, 0, '', '');
        },
      );

      await runner('/custom/bin/ffmpeg', const []);

      expect(invoked, ['/custom/bin/ffmpeg']);
    });
  });
}

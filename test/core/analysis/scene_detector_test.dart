import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/scene_detector.dart';
import 'package:ishkafel/core/ffmpeg/process_runner.dart';

const showinfoFixture = '''
[Parsed_showinfo_1 @ 0x60] n:   0 pts:  81081 pts_time:2.7027  duration_time:0.03 fmt:yuv420p
[Parsed_showinfo_1 @ 0x60] n:   1 pts: 240240 pts_time:8.008   duration_time:0.03 fmt:yuv420p
[Parsed_showinfo_1 @ 0x60] n:   2 pts: 360360 pts_time:12.012  duration_time:0.03 fmt:yuv420p
frame=    3 fps=0.0 q=-0.0 Lsize=N/A
''';

void main() {
  test('buildArgs 生成正确的场景检测参数', () {
    expect(
      SceneDetector.buildArgs(videoPath: '/v/a.mp4', threshold: 0.35),
      ['-i', '/v/a.mp4', '-vf', "select='gt(scene,0.35)',showinfo", '-f', 'null', '-'],
    );
  });

  test('parseBoundaryMs 从 showinfo stderr 解析毫秒时间点', () {
    expect(SceneDetector.parseBoundaryMs(showinfoFixture), [2703, 8008, 12012]);
  });

  test('detect 运行 ffmpeg 并解析 stderr', () async {
    final detector = SceneDetector(
        run: (_, _) async => ProcessResult(1, 0, '', showinfoFixture));
    expect(await detector.detect('/v/a.mp4'), [2703, 8008, 12012]);
  });

  test('无切换点的输出返回空列表', () async {
    final detector = SceneDetector(
        run: (_, _) async => ProcessResult(1, 0, '', 'frame= 0 fps=0.0'));
    expect(await detector.detect('/v/a.mp4'), isEmpty);
  });

  test('ffmpeg 失败抛 FfmpegException', () async {
    final detector = SceneDetector(
        run: (_, _) async => ProcessResult(1, 1, '', 'Invalid data'));
    expect(() => detector.detect('/v/a.mp4'), throwsA(isA<FfmpegException>()));
  });
}

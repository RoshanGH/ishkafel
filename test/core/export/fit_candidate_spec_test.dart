import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/ffmpeg/media_spec.dart';

/// 变速切片的编码规格。
///
/// 背景：预览是把「原片 → 变速切片 → 原片」拼成一条 EDL 交给 mpv 播。切片
/// 的编码和原片不一样，播放器走到接缝就要重建一次解码器——画面停一拍再赶
/// 上来，用户描述为「游标突然加速、突然变慢，连音轨也跟着变」（音轨是跟随
/// 轨，主时钟一停一赶就被判定为漂移，于是被 seek 拽一下）。
///
/// 所以预览这条路上，切片必须编成原片的规格。
void main() {
  const source = MediaSpec(
    codec: 'hevc',
    profile: 'Main 10',
    pixelFormat: 'yuv420p10le',
    width: 1080,
    height: 1920,
    frameRate: '30/1',
  );

  String valueAfter(List<String> args, String flag) =>
      args[args.indexOf(flag) + 1];

  group('给了原片规格（预览）', () {
    final args = ExportCommands.fitCandidateVideo(
      input: 'c.mp4',
      durationMs: 4000,
      candidateDurationMs: 6000,
      out: 'o.mp4',
      target: source,
    );

    test('编码器、profile、像素格式全部向原片看齐', () {
      expect(valueAfter(args, '-c:v'), 'hevc_videotoolbox');
      expect(valueAfter(args, '-profile:v'), 'main10');
      expect(valueAfter(args, '-pix_fmt'), 'p010le');
    });

    test('HEVC 打上 hvc1 标签，否则 macOS 有环节认不出来', () {
      expect(valueAfter(args, '-tag:v'), 'hvc1');
    });

    test('帧率与画幅也按原片，不按成片标准', () {
      expect(valueAfter(args, '-r'), '30/1');
      expect(valueAfter(args, '-vf'), contains('scale=1080:1920'));
    });

    test('该变速的还是变速——规格对齐不影响填坑', () {
      expect(valueAfter(args, '-vf'), contains('setpts=PTS/1.5'));
    });
  });

  test('原片是 8bit H.264 时跟着编成 8bit', () {
    final args = ExportCommands.fitCandidateVideo(
      input: 'c.mp4',
      durationMs: 4000,
      out: 'o.mp4',
      target: const MediaSpec(
        codec: 'h264',
        profile: 'High',
        pixelFormat: 'yuv420p',
        width: 720,
        height: 1280,
        frameRate: '25/1',
      ),
    );
    expect(valueAfter(args, '-c:v'), 'h264_videotoolbox');
    expect(valueAfter(args, '-pix_fmt'), 'yuv420p');
    expect(args, isNot(contains('-tag:v')));
    expect(valueAfter(args, '-vf'), contains('scale=720:1280'));
  });

  test('帧数按目标帧率算，否则切片会比坑位长出或短掉几帧', () {
    final at25 = ExportCommands.fitCandidateVideo(
      input: 'c.mp4',
      durationMs: 4000,
      out: 'o.mp4',
      target: const MediaSpec(
        codec: 'h264',
        profile: '',
        pixelFormat: 'yuv420p',
        width: 720,
        height: 1280,
        frameRate: '25/1',
      ),
    );
    expect(valueAfter(at25, '-frames:v'), '100');
    expect(ExportCommands.frameCount(4000), 120); // 不给规格时按成片 30fps
  });

  test('不给规格时（导出）还是老样子：统一 libx264、1080×1920、30fps', () {
    final args = ExportCommands.fitCandidateVideo(
      input: 'c.mp4',
      durationMs: 4000,
      out: 'o.mp4',
    );
    expect(valueAfter(args, '-c:v'), 'libx264');
    expect(valueAfter(args, '-pix_fmt'), 'yuv420p');
    expect(valueAfter(args, '-r'), '30');
    expect(valueAfter(args, '-vf'), contains('scale=1080:1920'));
    expect(valueAfter(args, '-frames:v'), '120');
  });

  test('帧率读不出来时退回成片标准，不会算出 0 帧', () {
    final args = ExportCommands.fitCandidateVideo(
      input: 'c.mp4',
      durationMs: 4000,
      out: 'o.mp4',
      target: const MediaSpec(
        codec: 'hevc',
        profile: '',
        pixelFormat: 'yuv420p',
        width: 1080,
        height: 1920,
        frameRate: '',
      ),
    );
    expect(valueAfter(args, '-frames:v'), '120');
  });
}

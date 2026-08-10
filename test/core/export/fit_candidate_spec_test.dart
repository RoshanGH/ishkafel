import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/ffmpeg/media_spec.dart';
import 'package:ishkafel/core/ffmpeg/proxy_spec.dart';

/// 变速切片编成什么规格。
///
/// 背景：预览是把「原片 → 变速切片 → 原片」拼成一条 EDL 交给 mpv 播。段与段
/// 规格不一致，播放器就要在接缝处重建解码器——真机上量到过从替换点起 1.67×
/// 连跑 6.5 秒（见 `docs/2026-08-10-预览接缝：变速镜头为什么会加速播放.md`）。
///
/// **曾经的解法是「向原片规格看齐」，已经废弃。** 它要求按原片的 HEVC Main 10
/// 硬编，而 Intel Mac 的 VideoToolbox 绝大多数编不了 10bit——换台机器就崩。
/// 现在统一编成代理规格（[ProxySpec]）：我们说了算、软编、哪台机器上都一样。
void main() {
  final proxy = ProxySpec.at('30/1');

  String valueAfter(List<String> args, String flag) =>
      args[args.indexOf(flag) + 1];

  group('预览：编成代理规格', () {
    final args = ExportCommands.fitCandidateVideo(
      input: 'c.mp4',
      durationMs: 4000,
      candidateDurationMs: 6000,
      out: 'o.mp4',
      target: proxy,
    );

    test('画幅与帧率按代理来，不按成片画幅', () {
      expect(valueAfter(args, '-vf'),
          contains('scale=${ProxySpec.width}:${ProxySpec.height}'));
      expect(valueAfter(args, '-r'), '30/1');
    });

    test('该变速的还是变速——规格统一不影响填坑', () {
      expect(valueAfter(args, '-vf'), contains('setpts=PTS/1.5'));
    });

    test('帧数按目标帧率算，否则切片会比坑位长出或短掉几帧', () {
      final at25 = ExportCommands.fitCandidateVideo(
        input: 'c.mp4',
        durationMs: 4000,
        out: 'o.mp4',
        target: ProxySpec.at('25/1'),
      );
      expect(valueAfter(at25, '-frames:v'), '100');
      expect(ExportCommands.frameCount(4000), 120); // 不给规格时按成片 30fps
    });

    test('帧率读不出来时退回成片标准，不会算出 0 帧', () {
      final args = ExportCommands.fitCandidateVideo(
        input: 'c.mp4',
        durationMs: 4000,
        out: 'o.mp4',
        target: ProxySpec.at(''),
      );
      expect(valueAfter(args, '-frames:v'), '120');
    });
  });

  group('一律软编——这正是要摆脱的那点机器相关性', () {
    test('给了代理规格也是 libx264，不是 videotoolbox', () {
      final args = ExportCommands.fitCandidateVideo(
        input: 'c.mp4', durationMs: 4000, out: 'o.mp4', target: proxy);
      expect(valueAfter(args, '-c:v'), 'libx264');
      expect(args.join(' '), isNot(contains('videotoolbox')));
    });

    test('哪怕目标写着 HEVC 10bit 也不去碰硬编', () {
      // 这是废弃路径的入参形状，留一条测试钉住它不会复活：
      // Intel Mac 上 -profile:v main10 会直接失败
      final args = ExportCommands.fitCandidateVideo(
        input: 'c.mp4',
        durationMs: 4000,
        out: 'o.mp4',
        target: const MediaSpec(
          codec: 'hevc',
          profile: 'Main 10',
          pixelFormat: 'yuv420p10le',
          width: 1080,
          height: 1920,
          frameRate: '30/1',
        ),
      );
      expect(valueAfter(args, '-c:v'), 'libx264');
      expect(valueAfter(args, '-pix_fmt'), 'yuv420p');
      expect(args.join(' '), isNot(contains('main10')));
      expect(args.join(' '), isNot(contains('p010')));
    });
  });

  test('导出：不给规格时还是老样子——1080×1920、30fps、libx264', () {
    final args = ExportCommands.fitCandidateVideo(
        input: 'c.mp4', durationMs: 4000, out: 'o.mp4');
    expect(valueAfter(args, '-c:v'), 'libx264');
    expect(valueAfter(args, '-pix_fmt'), 'yuv420p');
    expect(valueAfter(args, '-r'), '30');
    expect(valueAfter(args, '-vf'), contains('scale=1080:1920'));
    expect(valueAfter(args, '-frames:v'), '120');
  });
}

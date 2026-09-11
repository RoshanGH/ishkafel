@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/ffmpeg/proxy_spec.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';

/// 预览切片真的带得出声音——**跑真 ffmpeg，不看参数看产物**。
///
/// 这条命令有几处只有真跑才知道成不成：`-af` 和 `-filter_complex` 能不能
/// 共存、`-map 0:a?` 在素材没有音轨时会不会直接失败、`-shortest` 配
/// `-frames:v` 截出来的长度对不对。
///
/// 跑法：flutter test test/integration/fit_candidate_preview_audio_real_test.dart \
///   --tags integration --run-skipped
void main() {
  late Directory work;
  late String ffmpeg;
  late String ffprobe;

  String find(String name) =>
      ['/opt/homebrew/bin/$name', '/usr/local/bin/$name']
          .firstWhere((p) => File(p).existsSync(), orElse: () => name);

  setUpAll(() {
    ffmpeg = find('ffmpeg');
    ffprobe = find('ffprobe');
  });
  setUp(() => work = Directory.systemTemp.createTempSync('fitaudio_'));
  tearDown(() => work.deleteSync(recursive: true));

  Future<void> run(List<String> args) async {
    final r = await Process.run(ffmpeg, args);
    expect(r.exitCode, 0, reason: 'ffmpeg 失败：${r.stderr}');
  }

  /// 造一条 [seconds] 秒、带 [hz] 赫兹声音的竖屏素材
  Future<String> material(String name, double seconds, {int? hz}) async {
    final out = '${work.path}/$name.mp4';
    await run([
      '-y', '-v', 'error',
      '-f', 'lavfi', '-i',
      'testsrc=size=270x480:rate=30:duration=$seconds',
      if (hz != null) ...[
        '-f', 'lavfi', '-i',
        'sine=frequency=$hz:duration=$seconds:sample_rate=48000',
      ],
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      if (hz != null) ...['-c:a', 'aac'],
      '-t', '$seconds', out,
    ]);
    return out;
  }

  Future<String> probe(String path, String entries) async {
    final r = await Process.run(ffprobe, [
      '-v', 'error', '-show_entries', entries, '-of', 'csv=p=0', path,
    ]);
    return '${r.stdout}'.trim();
  }

  /// 造一张透明字幕图
  Future<String> subtitlePng() async {
    final out = '${work.path}/sub.png';
    await run([
      '-y', '-v', 'error',
      '-f', 'lavfi', '-i', 'color=c=white@0.5:s=${ProxySpec.width}x${ProxySpec.height}',
      '-frames:v', '1', out,
    ]);
    return out;
  }

  final proxy = ProxySpec.at('30/1');

  test('带声音的切片真的有音轨，长度就是坑位那么长', () async {
    final src = await material('m', 4.5, hz: 1000);
    final out = '${work.path}/fit.mp4';

    await run(ExportCommands.fitCandidateVideo(
      input: src,
      durationMs: 3000,
      candidateDurationMs: 4500,
      out: out,
      target: proxy,
      keepAudio: true,
    ));

    final codecs = await probe(out, 'stream=codec_type');
    expect(codecs, contains('audio'), reason: '切片没带出音轨来');
    expect(codecs, contains('video'));

    final seconds = double.parse(await probe(out, 'format=duration'));
    expect(seconds, closeTo(3.0, 0.1),
        reason: '1.5× 变速后 4.5 秒的素材正好填满 3 秒的坑位');
  });

  test('叠了字幕时同样带得出声音——那条路走的是 filter_complex', () async {
    final src = await material('m', 4.5, hz: 1000);
    final png = await subtitlePng();
    final out = '${work.path}/fit_sub.mp4';

    await run(ExportCommands.fitCandidateVideo(
      input: src,
      durationMs: 3000,
      candidateDurationMs: 4500,
      out: out,
      target: proxy,
      keepAudio: true,
      subtitleOverlays: [
        SubtitleOverlayImage(pngPath: png, startMs: 0, endMs: 1500),
      ],
    ));

    expect(await probe(out, 'stream=codec_type'), contains('audio'));
  });

  test('素材本身没有音轨时不许整条命令失败——只是这一层没声音', () async {
    final src = await material('mute', 4.5);
    final out = '${work.path}/fit_mute.mp4';

    await run(ExportCommands.fitCandidateVideo(
      input: src,
      durationMs: 3000,
      candidateDurationMs: 4500,
      out: out,
      target: proxy,
      keepAudio: true,
    ));

    expect(File(out).existsSync(), isTrue);
  });

  test('导出用的切片照旧不带音轨', () async {
    final src = await material('m', 4.5, hz: 1000);
    final out = '${work.path}/fit_export.mp4';

    await run(ExportCommands.fitCandidateVideo(
      input: src,
      durationMs: 3000,
      candidateDurationMs: 4500,
      out: out,
      target: proxy,
    ));

    expect(await probe(out, 'stream=codec_type'), isNot(contains('audio')));
  });
}

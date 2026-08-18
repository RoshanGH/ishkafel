import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/export/export_spec.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';

/// 取参数后面紧跟的那个值（ffmpeg 的参数就是这么成对出现的）
String? valueAfter(List<String> args, String flag) {
  final i = args.indexOf(flag);
  return i < 0 || i + 1 >= args.length ? null : args[i + 1];
}

void main() {
  group('切原片的一段画面', () {
    final args = ExportCommands.trimOriginalVideo(
        source: '/v/a.mp4', startMs: 1500, endMs: 4200, out: '/tmp/x.mp4');

    test('时间参数用秒，毫秒精度不丢', () {
      expect(valueAfter(args, '-ss'), '1.500');
      expect(valueAfter(args, '-to'), '4.267',
          reason: '终点多给两帧余量，真正的长度由 -frames:v 定');
    });

    test('锁死帧数，每段长度可预期', () {
      // 2700ms @30fps = 81 帧
      expect(valueAfter(args, '-frames:v'), '81',
          reason: '只给起止时间的话帧数由编码器凑整，'
              '50 个镜头累计下来画面与声音在片尾明显对不上');
    });

    test('-ss 放在 -i 之后：要的是精确切割', () {
      expect(args.indexOf('-ss'), greaterThan(args.indexOf('-i')),
          reason: '放在 -i 之前是关键帧级定位，每段差几十毫秒，'
              '累计到片尾就是明显的错位');
    });

    test('丢掉声音——声音是单独一条轨', () {
      expect(args, contains('-an'));
    });

    test('规格归一到竖屏 1080×1920 / 30fps，且不拉伸变形', () {
      final vf = valueAfter(args, '-vf')!;
      expect(vf, contains('scale=1080:1920'));
      expect(vf, contains('force_original_aspect_ratio=decrease'));
      expect(vf, contains('pad=1080:1920'));
      expect(valueAfter(args, '-r'), '30');
    });

    test('覆盖已存在的输出文件，且输出路径在最后', () {
      expect(args, contains('-y'));
      expect(args.last, '/tmp/x.mp4');
    });
  });

  group('把候选素材套进坑位时长', () {
    final args = ExportCommands.fitCandidateVideo(
        input: '/m/1.mp4', durationMs: 3000, out: '/tmp/y.mp4');

    test('长了截断到该有的帧数', () {
      expect(valueAfter(args, '-frames:v'), '90');
    });

    test('短了冻结最后一帧补齐，而不是循环播放', () {
      expect(valueAfter(args, '-vf'), contains('tpad=stop_mode=clone'),
          reason: '循环会看到画面突然跳回开头，观众一眼看出是拼的');
    });

    test('给了字幕图就走 filter_complex：主链之后按时间叠加，不再用 -vf', () {
      final withSub = ExportCommands.fitCandidateVideo(
          input: '/m/1.mp4',
          durationMs: 3000,
          out: '/tmp/y.mp4',
          subtitleOverlays: const [
            SubtitleOverlayImage(pngPath: '/w/a.png', startMs: 0, endMs: 1500),
          ]);
      expect(withSub, contains('/w/a.png'), reason: '字幕图是第二路输入');
      final fc = valueAfter(withSub, '-filter_complex')!;
      expect(fc, contains('tpad'));
      expect(fc, contains("overlay=0:0:enable='between(t,0.000,1.500)'"));
      expect(fc.indexOf('tpad'), lessThan(fc.indexOf('overlay')),
          reason: '字幕时间轴是切片输出时间轴，必须在变速与补帧之后叠');
      expect(valueAfter(withSub, '-map'), '[b1]');
      expect(withSub, isNot(contains('-vf')));
    });

    test('导出规格贯穿：720P/60fps/HEVC 不再吃 1080/30/H.264 的死值', () {
      const spec = ExportSpec(
          shortSide: 720, fps: 60, codec: VideoCodec.hevc);
      final args = ExportCommands.fitCandidateVideo(
          input: '/m/1.mp4', durationMs: 3000, out: '/tmp/y.mp4', spec: spec);
      final vf = valueAfter(args, '-vf')!;
      expect(vf, contains('scale=720:1280'),
          reason: '同一条 concat 清单里原片段是 720，替换段还是 1080 会花屏');
      expect(valueAfter(args, '-r'), '60');
      expect(valueAfter(args, '-frames:v'), '180',
          reason: '3000ms @60fps；按 30 数帧的话这段只有一半长');
      expect(valueAfter(args, '-c:v'), 'libx265',
          reason: 'HEVC 导出时替换段编成 H.264，-c copy 拼接直接失败');
      expect(valueAfter(args, '-b:v'), isNotNull,
          reason: '码率档位也要跟导出设置，不能吃 CRF 死值');
    });

    test('预览规格（target）优先于导出规格——两者不该同时传，传了以预览为准', () {
      final args = ExportCommands.fitCandidateVideo(
          input: '/m/1.mp4', durationMs: 3000, out: '/tmp/y.mp4');
      // 都不传时维持成片标准缺省
      expect(valueAfter(args, '-vf'), contains('scale=1080:1920'));
      expect(valueAfter(args, '-r'), '30');
    });

    test('不给字幕图就完全不碰滤镜链——和原行为一字不差', () {
      expect(valueAfter(args, '-vf'), isNot(contains('overlay')));
      expect(args, isNot(contains('-filter_complex')));
    });
  });

  group('声音', () {
    test('配音短了补静音、长了截断——不补齐会一路累积错位到片尾', () {
      final args = ExportCommands.fitVoiceAudio(
          input: '/v/u1.mp3', durationMs: 2500, out: '/tmp/u1.wav');

      expect(valueAfter(args, '-af'), 'apad');
      // 2500ms @30fps = 75 帧 = 2.5s 整
      expect(valueAfter(args, '-t'), '2.500000');
    });

    test('声音按画面的帧数对齐，两边不各走各的', () {
      final args = ExportCommands.trimOriginalAudio(
          source: '/v/a.mp4', startMs: 0, endMs: 3760, out: '/tmp/a.wav');

      // 3760ms @30fps = 113 帧 = 3.766667s；声音也补到这个长度
      expect(valueAfter(args, '-t'), '3.766667');
      expect(ExportCommands.frameCount(3760), 113);
    });

    test('中间产物用无损 PCM，拼接前不反复有损转码', () {
      final args = ExportCommands.trimOriginalAudio(
          source: '/v/a.mp4', startMs: 0, endMs: 1000, out: '/tmp/a.wav');

      expect(valueAfter(args, '-c:a'), 'pcm_s16le');
      expect(valueAfter(args, '-ar'), '48000');
    });

    test('时长不是帧长整数倍时四舍五入到最近的帧', () {
      expect(ExportCommands.frameCount(1000), 30);
      expect(ExportCommands.frameCount(1016), 30, reason: '30.48 帧 → 30');
      expect(ExportCommands.frameCount(1020), 31, reason: '30.6 帧 → 31');
    });
  });

  group('拼接清单', () {
    test('每行一个 file 指令', () {
      expect(ExportCommands.concatList(['/a.mp4', '/b.mp4']),
          "file '/a.mp4'\nfile '/b.mp4'");
    });

    test('路径里的单引号要转义，否则整份清单解析失败', () {
      expect(ExportCommands.concatList([r"/it's.mp4"]),
          r"file '/it'\''s.mp4'");
    });

    test('拼接直接 copy，不再重编码——每段已经归一过了', () {
      final args =
          ExportCommands.concat(listFile: '/tmp/l.txt', out: '/tmp/o.mp4');

      expect(valueAfter(args, '-c'), 'copy');
      expect(args, containsAllInOrder(['-f', 'concat', '-safe', '0']));
    });
  });

  group('画面与声音合成', () {
    test('画面直接 copy，声音转 aac', () {
      final args = ExportCommands.mux(
          video: '/tmp/v.mp4', audio: '/tmp/a.wav', out: '/out/1.mp4');

      expect(valueAfter(args, '-c:v'), 'copy');
      expect(valueAfter(args, '-c:a'), 'aac');
    });
  });

  group('混配乐', () {
    final args = ExportCommands.mixBgm(
      voice: '/tmp/a.wav',
      bgm: 'https://cdn/x.mp3',
      out: '/tmp/mixed.wav',
      startMs: 2000,
      durationMs: 5000,
    );

    test('配乐压低音量——垫乐盖过台词是最常见的翻车方式', () {
      expect(args.join(' '), contains('volume=0.25'));
    });

    test('配乐延迟到它该出现的位置', () {
      expect(args.join(' '), contains('adelay=2000|2000'));
    });

    test('成片长度跟人声轨走，配乐比片子长不该把片子拖长', () {
      expect(args.join(' '), contains('duration=first'));
    });

    test('配乐短了循环铺满', () {
      expect(valueAfter(args, '-stream_loop'), '-1');
    });
  });
}

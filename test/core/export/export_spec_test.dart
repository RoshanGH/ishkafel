import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/export/export_spec.dart';

/// 导出规格。选项对齐剪映专业版的导出面板：
/// 分辨率 480P/720P/1080P/2K/4K、帧率 24/25/30/50/60、
/// 码率 更低/推荐/更高/自定义、编码 H.264/HEVC、格式 mp4/mov。
void main() {
  String argAfter(List<String> args, String flag) =>
      args[args.indexOf(flag) + 1];

  List<String> whole(ExportSpec spec) =>
      ExportCommands.wholeReplacementVideo(
          input: 'a.mp4', out: 'o.mp4', spec: spec);

  group('分辨率', () {
    test('竖屏 9:16：短边就是宽，1080P 是 1080×1920', () {
      expect(const ExportSpec(shortSide: 1080).width, 1080);
      expect(const ExportSpec(shortSide: 1080).height, 1920);
    });

    test('剪映那五档都在，且高都是偶数（yuv420p 的硬要求）', () {
      expect(ExportSpec.resolutions.map((r) => r.label),
          ['480P', '720P', '1080P', '2K', '4K']);
      for (final r in ExportSpec.resolutions) {
        final spec = ExportSpec(shortSide: r.shortSide);
        expect(spec.height.isEven, isTrue, reason: '${r.label} 的高必须是偶数');
      }
    });

    test('缩放补黑边，绝不拉伸变形', () {
      final args = whole(const ExportSpec(shortSide: 720));
      expect(argAfter(args, '-vf'), contains('720:1280'));
      expect(argAfter(args, '-vf'), contains('force_original_aspect_ratio=decrease'));
    });
  });

  group('帧率', () {
    test('剪映那五档都在', () {
      expect(ExportSpec.frameRates, [24, 25, 30, 50, 60]);
    });

    test('选了多少就按多少输出', () {
      expect(argAfter(whole(const ExportSpec(fps: 60)), '-r'), '60');
      expect(argAfter(whole(const ExportSpec(fps: 24)), '-r'), '24');
    });

    test('切原片按导出帧率数帧——按 30 数而导出 60，片段只有一半长', () {
      final at60 = ExportCommands.trimOriginalVideo(
          source: 'a.mp4',
          startMs: 0,
          endMs: 1000,
          out: 'o.mp4',
          spec: const ExportSpec(fps: 60));
      expect(argAfter(at60, '-frames:v'), '60');

      final at24 = ExportCommands.trimOriginalVideo(
          source: 'a.mp4',
          startMs: 0,
          endMs: 1000,
          out: 'o.mp4',
          spec: const ExportSpec(fps: 24));
      expect(argAfter(at24, '-frames:v'), '24');
    });

    test('声音和画面按同一个帧率取整，否则一路累积到片尾会错位', () {
      final audio = ExportCommands.trimOriginalAudio(
          source: 'a.mp4', startMs: 0, endMs: 1000, out: 'o.wav', atFps: 60);
      // 1 秒 @60fps = 60 帧 = 1.000000 秒
      expect(double.parse(argAfter(audio, '-t')), closeTo(1.0, 0.001));
    });
  });

  group('码率', () {
    test('档位是具体数字：1080P@30 推荐档 = 12 Mbps', () {
      // 界面上写多少就编多少——档位不是玄学，是按分辨率 × 帧率算出的码率
      expect(const ExportSpec().kbps, 12000);
      expect(const ExportSpec(bitrate: BitrateMode.lower).kbps, 7000);
      expect(const ExportSpec(bitrate: BitrateMode.higher).kbps, 17000);
    });

    test('分辨率或帧率一变，同一档的码率跟着变', () {
      const base = ExportSpec();
      expect(base.copyWith(shortSide: 720).kbps, lessThan(base.kbps));
      expect(base.copyWith(fps: 60).kbps, greaterThan(base.kbps));
    });

    test('编码参数按算出的码率定死，带 maxrate/bufsize', () {
      // 只给 -b:v 的话那是个平均值，峰值段照样糊
      final args = whole(const ExportSpec());
      expect(argAfter(args, '-b:v'), '12000k');
      expect(argAfter(args, '-maxrate'), '12000k');
      expect(argAfter(args, '-bufsize'), '24000k');
    });

    test('自定义按填入的数字来', () {
      final args = whole(const ExportSpec(
          bitrate: BitrateMode.custom, customKbps: 30000));
      expect(argAfter(args, '-b:v'), '30000k');
    });
  });

  group('编码与格式', () {
    test('H.264 默认', () {
      expect(argAfter(whole(const ExportSpec()), '-c:v'), 'libx264');
    });

    test('HEVC 要标 hvc1，否则 macOS 播放器与相册认不出来', () {
      final args = whole(const ExportSpec(codec: VideoCodec.hevc));
      expect(argAfter(args, '-c:v'), 'libx265');
      expect(argAfter(args, '-tag:v'), 'hvc1');
    });

    test('扩展名跟着格式走', () {
      expect(const ExportSpec().fileExtension, 'mp4');
      expect(const ExportSpec(format: ContainerFormat.mov).fileExtension, 'mov');
    });
  });

  group('缓存指纹', () {
    test('规格不同指纹就不同——否则第二次导出会拿到第一次的产物', () {
      const base = ExportSpec();
      final prints = {
        base.fingerprint,
        base.copyWith(shortSide: 720).fingerprint,
        base.copyWith(fps: 60).fingerprint,
        base.copyWith(bitrate: BitrateMode.higher).fingerprint,
        base.copyWith(codec: VideoCodec.hevc).fingerprint,
      };
      expect(prints, hasLength(5));
    });
  });

  group('存取', () {
    test('往返不丢东西', () {
      const spec = ExportSpec(
        shortSide: 2160,
        fps: 60,
        bitrate: BitrateMode.custom,
        customKbps: 80000,
        codec: VideoCodec.hevc,
        format: ContainerFormat.mov,
      );
      expect(ExportSpec.fromJson(spec.toJson()), spec);
    });

    test('存坏了退回标准档，不是崩掉', () {
      expect(ExportSpec.fromJson('乱写'), ExportSpec.standard);
      expect(ExportSpec.fromJson(null), ExportSpec.standard);
      expect(ExportSpec.fromJson({'codec': '不存在的编码'}).codec, VideoCodec.h264);
    });
  });
}

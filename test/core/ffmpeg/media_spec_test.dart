import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ffmpeg/media_spec.dart';
import 'package:ishkafel/core/ffmpeg/proxy_spec.dart';

const _source = MediaSpec(
  codec: 'hevc',
  profile: 'Main 10',
  pixelFormat: 'yuv420p10le',
  width: 1080,
  height: 1920,
  frameRate: '30/1',
);

void main() {
  group('解码规格比对', () {
    test('真机上那条差异：只差 profile 与色深，也要判成不同', () {
      // 原片 HEVC Main 10、素材库给的候选 HEVC Main，其余全一样。
      // 就这一处不同，播放器在替换点要重建解码器，画面停约 100ms
      const candidate = MediaSpec(
        codec: 'hevc',
        profile: 'Main',
        pixelFormat: 'yuv420p',
        width: 1080,
        height: 1920,
        frameRate: '30/1',
      );

      expect(_source.sameAs(candidate), isFalse);
    });

    test('完全一致就一致', () {
      expect(_source.sameAs(_source), isTrue);
    });

    test('29.97 与 30000/1001 是同一个帧率，不能按字符串比', () {
      const a = MediaSpec(
          codec: 'hevc',
          profile: 'Main',
          pixelFormat: 'yuv420p',
          width: 1080,
          height: 1920,
          frameRate: '30000/1001');
      const b = MediaSpec(
          codec: 'hevc',
          profile: 'Main',
          pixelFormat: 'yuv420p',
          width: 1080,
          height: 1920,
          frameRate: '29.97');

      expect(a.sameAs(b), isTrue);
    });

    test('分辨率不同当然不同', () {
      const small = MediaSpec(
          codec: 'hevc',
          profile: 'Main 10',
          pixelFormat: 'yuv420p10le',
          width: 720,
          height: 1280,
          frameRate: '30/1');

      expect(_source.sameAs(small), isFalse);
    });
  });

  group('解析 ffprobe 输出', () {
    test('认得出真机那份输出', () {
      const output = '''
codec_name=hevc
profile=Main 10
width=1080
height=1920
pix_fmt=yuv420p10le
r_frame_rate=30/1
''';

      final spec = MediaSpec.tryParse(output);

      expect(spec, isNotNull);
      expect(spec!.sameAs(_source), isTrue);
    });

    test('缺关键字段时返回 null——宁可不转，也不能拿瞎猜的规格去转', () {
      expect(MediaSpec.tryParse('codec_name=hevc'), isNull);
      expect(MediaSpec.tryParse(''), isNull);
    });
  });

  group('转码参数', () {
    // 「向原片规格看齐」那套（MaterialNormalizer）已随代理方案退休：
    // 它要求按原片的 HEVC Main 10 硬编，而 Intel Mac 的 VideoToolbox
    // 绝大多数编不了 10bit。现在统一编成 ProxySpec，测试见
    // test/core/export/export_uses_original_test.dart
    test('代理规格一律软编、不碰 10bit', () {
      final args = ProxySpec.encodeArgs(
          input: '/m/a.mp4', frameRate: '30/1', out: '/m/out.mp4');

      expect(args[args.indexOf('-c:v') + 1], 'libx264');
      expect(args[args.indexOf('-pix_fmt') + 1], 'yuv420p');
      expect(args.join(' '), isNot(contains('videotoolbox')));
    });

    test('声音原样拷贝——重编会白损一道音质，和接缝顿挫无关', () {
      final args = ProxySpec.encodeArgs(
          input: '/m/a.mp4', frameRate: '30/1', out: '/m/out.mp4');

      expect(args[args.indexOf('-c:a') + 1], 'copy');
    });

    test('画幅是代理的固定画幅，帧率跟着原片', () {
      final args = ProxySpec.encodeArgs(
          input: '/m/a.mp4', frameRate: '30/1', out: '/m/out.mp4');

      expect(args[args.indexOf('-vf') + 1],
          contains('scale=${ProxySpec.width}:${ProxySpec.height}'));
      expect(args[args.indexOf('-r') + 1], '30/1');
    });
  });
}

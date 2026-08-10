import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/ffmpeg/media_spec.dart';
import 'package:ishkafel/core/ffmpeg/proxy_spec.dart';

/// **导出一律走原始素材，绝不能碰预览代理。**
///
/// 预览链路上的每一段都被转成 720×1280 的代理规格（见 [ProxySpec]），
/// 为的是让拼接规格统一、让 Intel 机器也编得动。但代理是低码率小画幅的，
/// 拿它导出等于把成片画质砍掉——而且这种事**不会报错**，只会安静地交出一批
/// 糊片子，等发现时素材可能已经发出去了。
///
/// 这条边界目前是靠两条取材路径天然分开维持的：
///   导出   main.dart → MaterialDownloader.fetch      → material_cache/ 原始下载
///   预览   workbench → PickedMediaCache(代理化 fetch) → 代理目录
///
/// 「天然分开」意味着没有任何东西挡着它被改坏。这组测试就是那个挡着的东西。
void main() {
  group('导出的画面参数不许退化成预览代理', () {
    String valueAfter(List<String> args, String flag) =>
        args[args.indexOf(flag) + 1];

    test('原片切段：按成片画幅 1080×1920，不是代理的 720×1280', () {
      final args = ExportCommands.trimOriginalVideo(
          source: 'src.mp4', startMs: 0, endMs: 1000, out: 'o.mp4');
      final vf = valueAfter(args, '-vf');
      expect(vf, contains('${ExportCommands.width}:${ExportCommands.height}'));
      expect(vf, isNot(contains('${ProxySpec.width}:${ProxySpec.height}')));
    });

    test('整体替换：同样是成片画幅', () {
      final args =
          ExportCommands.wholeReplacementVideo(input: 'c.mp4', out: 'o.mp4');
      final vf = valueAfter(args, '-vf');
      expect(vf, contains('${ExportCommands.width}:${ExportCommands.height}'));
      expect(vf, isNot(contains('${ProxySpec.width}:${ProxySpec.height}')));
    });

    test('镜头替换变速：不传目标规格时就是成片规格', () {
      final args = ExportCommands.fitCandidateVideo(
          input: 'c.mp4', durationMs: 1000, out: 'o.mp4');
      final vf = valueAfter(args, '-vf');
      expect(vf, contains('${ExportCommands.width}:${ExportCommands.height}'));
      expect(vf, isNot(contains('${ProxySpec.width}:${ProxySpec.height}')));
    });

    test('成片画幅本身不能被改小到代理那个量级', () {
      expect(ExportCommands.width, greaterThan(ProxySpec.width));
      expect(ExportCommands.height, greaterThan(ProxySpec.height));
    });
  });

  group('导出取的是 material_cache 的原始下载', () {
    test('接线上导出与预览用的是两个不同的取材函数', () async {
      // 真机接线在 main.dart：
      //   exportRunnerFactoryProvider → fetchMaterial: MaterialDownloader(...).fetch
      //   workbench                   → PickedMediaCache(fetch: 代理化(...))
      // 这里用同名替身把「导出那一路不做任何转换」这条性质钉住
      const original = '/material_cache/114799.mp4';
      Future<String> exportFetch(int id) async => original;
      Future<String> previewFetch(int id) async => '/proxy/norm_abc.mp4';

      expect(await exportFetch(114799), original);
      expect(await previewFetch(114799), isNot(original),
          reason: '预览会换成代理——正因如此，导出那一路必须保持原样');
    });
  });

  group('代理规格本身的约束', () {
    test('用软编，不依赖本机能编什么', () {
      final args = ProxySpec.encodeArgs(
          input: 'a.mp4', frameRate: '30/1', out: 'b.mp4');
      expect(args, contains('libx264'));
      expect(args.join(' '), isNot(contains('videotoolbox')),
          reason: '硬编的规格支持是机器相关的，而代理方案的全部意义就是摆脱这一点');
    });

    test('不碰 10bit——Intel 的 VideoToolbox 编不了，这正是要绕开的东西', () {
      expect(ProxySpec.pixelFormat, 'yuv420p');
      final args = ProxySpec.encodeArgs(
          input: 'a.mp4', frameRate: '30/1', out: 'b.mp4');
      expect(args.join(' '), isNot(contains('p010')));
      expect(args.join(' '), isNot(contains('main10')));
    });

    test('帧率跟着原片走，不写死——切分边界是按帧对齐的', () {
      final args = ProxySpec.encodeArgs(
          input: 'a.mp4', frameRate: '25/1', out: 'b.mp4');
      expect(args[args.indexOf('-r') + 1], '25/1');
    });

    test('声音原样拷贝，不重编', () {
      final args = ProxySpec.encodeArgs(
          input: 'a.mp4', frameRate: '30/1', out: 'b.mp4');
      expect(args[args.indexOf('-c:a') + 1], 'copy');
    });

    test('已经是代理规格的文件认得出来，不白转一遍', () {
      expect(ProxySpec.matches(ProxySpec.at('30/1')), isTrue);
      // 帧率不同也算命中：代理帧率本来就是跟着原片定的
      expect(ProxySpec.matches(ProxySpec.at('25/1')), isTrue);
    });

    test('原片那种规格不算命中，该转还得转', () {
      expect(
          ProxySpec.matches(const MediaSpec(
            codec: 'hevc',
            profile: 'Main 10',
            pixelFormat: 'yuv420p10le',
            width: 1080,
            height: 1920,
            frameRate: '30/1',
          )),
          isFalse);
    });
  });
}

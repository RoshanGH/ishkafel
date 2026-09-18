import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/subtitle/subtitle_font.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_rasterizer.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';
import 'package:path/path.dart' as p;

/// 烧进成片的字幕必须用随包自带的字体。
///
/// 2026-09-18 用户问：「比如字幕烧录的这个字体可以商用吗？我需要它是可以
/// 商用的。」答案是不能——原来用的是苹方（`PingFangSC-Semibold`），
/// 那是 Apple 的系统字体；取不到时退回的系统粗体在 Windows 上会落到微软
/// 雅黑，那是微软向方正授权的。两者的许可都只覆盖「在本系统上显示和打印
/// 内容」，**都没有授予「把渲染结果烧进对外交付的商业成片」这项权利**。
///
/// 而这个软件的出口正是要交给客户的片子，字幕烧进画面像素，还要矩阵导出
/// 批量产出。换成 Noto Sans SC（SIL OFL 1.1，明确允许商业使用与嵌入）。
void main() {
  group('字体从哪儿找', () {
    test('打包版：从 .app 里的 Contents/Resources/fonts 取', () {
      final dirs = SubtitleFont.searchDirs(
        executablePath: '/Applications/ishkafel.app/Contents/MacOS/ishkafel',
        workingDir: Directory('/'),
      );
      expect(dirs.first,
          '/Applications/ishkafel.app/Contents/Resources/fonts');
    });

    test('包里的命令行工具：同样落到那份字体上', () {
      // CLI 在 Contents/Resources/cli/<架构>/bundle/bin/ 下，比 GUI 深好几层。
      // 两边找的必须是同一份——不然「界面导得出、Agent 导不出」
      final dirs = SubtitleFont.searchDirs(
        executablePath: '/Applications/ishkafel.app/Contents/Resources/cli/'
            'arm64/bundle/bin/ishkafel',
        workingDir: Directory('/'),
      );
      expect(dirs.first,
          '/Applications/ishkafel.app/Contents/Resources/fonts');
    });

    test('开发期：从工作目录逐级往上找 assets/fonts', () {
      final dirs = SubtitleFont.searchDirs(
        executablePath: '/usr/local/bin/dart',
        workingDir: Directory('/Users/x/repo/sub/dir'),
      );
      expect(dirs, contains('/Users/x/repo/sub/dir/assets/fonts'));
      expect(dirs, contains('/Users/x/repo/assets/fonts'),
          reason: 'flutter test 的工作目录不一定在仓库根上');
    });

    test('可执行文件旁边的 fonts/ 也认（Windows 是平铺布局）', () {
      final dirs = SubtitleFont.searchDirs(
        executablePath: r'/opt/ishkafel/ishkafel',
        workingDir: Directory('/'),
      );
      expect(dirs, contains('/opt/ishkafel/fonts'));
    });

    test('ISHKAFEL_SUBTITLE_FONT 指到哪儿就用哪儿', () {
      final tmp = Directory.systemTemp.createTempSync('fontenv');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final f = File(p.join(tmp.path, 'custom.otf'))..writeAsStringSync('x');

      final found = SubtitleFont.locate(env: {'ISHKAFEL_SUBTITLE_FONT': f.path});
      expect(found?.path, f.path);
    });

    test('指定的那份不存在时返回 null，不悄悄换一份', () {
      final found = SubtitleFont.locate(
          env: {'ISHKAFEL_SUBTITLE_FONT': '/nope/missing.otf'});
      expect(found, isNull,
          reason: '人显式指定了一份却没找到，回落到别的字体等于把他的指定吃掉');
    });

    test('仓库里真的有这份字体，且许可原文也在', () {
      // 少了字体，打出来的包导出时会失败；少了许可，OFL 的分发条件没满足
      final font = SubtitleFont.locate(
          env: const {}, executablePath: '/nonexistent/exe');
      expect(font, isNotNull, reason: 'assets/fonts/${SubtitleFont.fileName}');
      expect(File(p.join(p.dirname(font!.path), 'LICENSE-NotoSansSC.txt'))
          .existsSync(), isTrue,
          reason: 'SIL OFL 要求随字体一起分发许可原文');
    });
  });

  group('渲染器把字体交给 AppKit', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('subfont'));
    tearDown(() => dir.deleteSync(recursive: true));

    List<SubtitleLine> lines(List<String> texts) => [
          for (var i = 0; i < texts.length; i++)
            SubtitleLine(text: texts[i], startMs: i * 1000, endMs: i * 1000 + 900),
        ];

    test('spec 里带上字体路径与 PostScript 名', () async {
      Map<String, dynamic>? seen;
      await SubtitleRasterizer(run: (bin, args) async {
        seen = jsonDecode(File(args.last).readAsStringSync())
            as Map<String, dynamic>;
        for (final it in (seen!['items'] as List)) {
          File(it['out'] as String).writeAsStringSync('png');
        }
        return ProcessResult(1, 0, '', '');
      }).rasterize(
        lines: lines(['这个东西能把衣服洗干净']),
        width: 1080,
        height: 1920,
        style: const SubtitleStyle(),
        outDir: dir,
      );

      expect(seen!['fontName'], SubtitleFont.postScriptName);
      expect(seen!['fontPath'], endsWith(SubtitleFont.fileName));
      expect(File(seen!['fontPath'] as String).existsSync(), isTrue);
    });

    test('字体版本进了缓存指纹：换了字体不会复用旧字体渲的图', () async {
      // 指纹在文件名里。旧版渲出来的 subimg_<指纹>.png 必须命不中新指纹，
      // 否则用户装了新版、导出来的还是苹方那批图，而哪儿都不报错
      late String name;
      await SubtitleRasterizer(run: (bin, args) async {
        final spec = jsonDecode(File(args.last).readAsStringSync());
        name = p.basename((spec['items'] as List).first['out'] as String);
        for (final it in (spec['items'] as List)) {
          File(it['out'] as String).writeAsStringSync('png');
        }
        return ProcessResult(1, 0, '', '');
      }).rasterize(
        lines: lines(['这个东西能把衣服洗干净']),
        width: 1080,
        height: 1920,
        style: const SubtitleStyle(),
        outDir: dir,
      );

      expect(name, contains(SubtitleFont.renderRevision));
    });
  });

  group('不许悄悄退回系统字体', () {
    test('JXA 脚本里不再出现苹方，也没有 boldSystemFont 兜底', () {
      final src = File('lib/core/subtitle/subtitle_rasterizer.dart')
          .readAsStringSync();
      expect(src, isNot(contains('PingFang')),
          reason: '苹方不许再出现在渲字这条路上');
      expect(src, isNot(contains('boldSystemFontOfSize')),
          reason: '退回系统粗体等于把授权问题放回来，而且成片会静默变样——'
              '人看不出来（字幕照样渲得出），但交付出去的用的是没授权的字体');
      expect(src, contains('CTFontManagerRegisterFontsForURL'),
          reason: '随包字体要先注册进本进程才取得到');
    });

    test('找不到字体时的话说得清楚：缺什么、为什么不兜底、人能做什么', () {
      final m = SubtitleFont.missingMessage;
      expect(m, contains(SubtitleFont.fileName));
      expect(m, contains('assets/fonts'));
      expect(m, contains('Contents/Resources/fonts'));
      expect(m, contains('ISHKAFEL_SUBTITLE_FONT'));
    });
  });
}

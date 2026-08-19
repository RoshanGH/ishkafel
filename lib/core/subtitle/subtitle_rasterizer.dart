import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/process_runner.dart';
import 'subtitle_overlay.dart';
import 'subtitle_style.dart';

/// 把字幕行渲成透明 PNG——文字交给 macOS 自带的系统渲染（AppKit，经
/// osascript 的 JXA 调用），不依赖 ffmpeg 编没编 libass/freetype。
///
/// 产物按内容指纹命名（文本 + 样式 + 分辨率），已存在就不重渲；一次
/// osascript 进程渲完这一批缺的，不是一句一个进程。
class SubtitleRasterizer {
  final ProcessRunner run;

  SubtitleRasterizer({this.run = systemProcessRunner});

  /// 把 [lines] 渲成 PNG，返回与 overlay 滤镜对接的图。
  /// 渲染失败直接抛——字幕是成片内容，悄悄少一句正是不允许的那类错。
  Future<List<SubtitleOverlayImage>> rasterize({
    required List<SubtitleLine> lines,
    required int width,
    required int height,
    required SubtitleStyle style,
    required Directory outDir,
  }) async {
    if (lines.isEmpty) return const [];
    outDir.createSync(recursive: true);

    final images = <SubtitleOverlayImage>[];
    final missing = <Map<String, String>>[];
    for (final line in lines) {
      final key = _fingerprint(line.text, width, height, style);
      final out = p.join(outDir.path, 'subimg_$key.png');
      images.add(SubtitleOverlayImage(
          pngPath: out, startMs: line.startMs, endMs: line.endMs));
      if (!File(out).existsSync()) {
        missing.add({'text': line.text, 'out': out});
      }
    }
    if (missing.isEmpty) return List.unmodifiable(images);

    final script = File(p.join(outDir.path, 'subrender.js'))
      ..writeAsStringSync(_jxaScript);
    final custom = style.colorHex;
    final (r, g, b) = custom != null
        ? (
            int.parse(custom.substring(0, 2), radix: 16) / 255,
            int.parse(custom.substring(2, 4), radix: 16) / 255,
            int.parse(custom.substring(4, 6), radix: 16) / 255,
          )
        : switch (style.preset) {
            SubtitlePreset.yellowOutline => (1.0, 0.85, 0.0),
            _ => (1.0, 1.0, 1.0),
          };
    final spec = File(p.join(outDir.path, 'subrender_spec.json'))
      ..writeAsStringSync(jsonEncode({
        'width': width,
        'height': height,
        'fontSize': (height * style.fontRatio).round(),
        'marginV': (height * style.bottomRatio).round(),
        // 描边占字号的百分比。对标原片字幕的重描边（粗黑边 + 实心白字，
        // 见 2026-08-18 用户给的样张）；底条预设描边收细
        'strokePercent': style.preset == SubtitlePreset.whiteBox ? 3 : 9,
        'r': r,
        'g': g,
        'b': b,
        'box': style.preset == SubtitlePreset.whiteBox,
        'items': missing,
      }));

    final result =
        await run('osascript', ['-l', 'JavaScript', script.path, spec.path]);
    if (result.exitCode != 0) {
      throw StateError('字幕渲染失败（osascript exit=${result.exitCode}）：'
          '${result.stderr}'.trim());
    }
    final bad = [
      for (final m in missing)
        if (!File(m['out']!).existsSync()) m['text'],
    ];
    if (bad.isNotEmpty) {
      throw StateError('字幕渲染失败：「${bad.first}」等 ${bad.length} 句没有产出图片');
    }
    return List.unmodifiable(images);
  }

  static String _fingerprint(
          String text, int width, int height, SubtitleStyle style) =>
      '${text.hashCode.toRadixString(16)}_${width}x$height'
      '_${style.fingerprint.hashCode.toRadixString(16)}';
}

/// AppKit 渲字（JXA）。白字黑描边（NSStrokeWidth 负值 = 描边 + 填充），
/// 底部居中、按宽度折行；box 预设先铺半透明圆角底再画字。
/// 真机验证过：中文（PingFang SC）、折行、透明通道都正常。
const String _jxaScript = r'''
function run(argv) {
  ObjC.import('Cocoa');
  const data = $.NSData.dataWithContentsOfFile(argv[0]);
  const spec = JSON.parse($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding).js);
  const w = spec.width, h = spec.height;
  for (const it of spec.items) {
    const rep = $.NSBitmapImageRep.alloc
      .initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
        null, w, h, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
    $.NSGraphicsContext.saveGraphicsState;
    $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
    let font = $.NSFont.fontWithNameSize('PingFangSC-Semibold', spec.fontSize);
    if (font.isNil()) font = $.NSFont.boldSystemFontOfSize(spec.fontSize);
    const para = $.NSMutableParagraphStyle.alloc.init;
    // NSTextAlignmentCenter：新 SDK 里是 1（老 AppKit 的 2 现在是右对齐，
    // 真机上就是被它坑出了「从右往左排」）
    para.setAlignment(1);
    // 两遍绘制：先用「仅描边」（正值）画粗黑边打底，再画实心字芯——
    // 描边和填充一遍画（负值）时，描边一粗就会吃进字的内部
    const strokeAttrs = $.NSMutableDictionary.alloc.init;
    strokeAttrs.setObjectForKey(font, $.NSFontAttributeName);
    strokeAttrs.setObjectForKey($.NSColor.blackColor, $.NSStrokeColorAttributeName);
    strokeAttrs.setObjectForKey($.NSNumber.numberWithDouble(spec.strokePercent * 2), $.NSStrokeWidthAttributeName);
    strokeAttrs.setObjectForKey(para, $.NSParagraphStyleAttributeName);
    const attrs = $.NSMutableDictionary.alloc.init;
    attrs.setObjectForKey(font, $.NSFontAttributeName);
    attrs.setObjectForKey($.NSColor.colorWithSRGBRedGreenBlueAlpha(spec.r, spec.g, spec.b, 1), $.NSForegroundColorAttributeName);
    // 字芯自身再带一圈同色细描边，撑出样张里那种饱满的字重
    attrs.setObjectForKey($.NSColor.colorWithSRGBRedGreenBlueAlpha(spec.r, spec.g, spec.b, 1), $.NSStrokeColorAttributeName);
    attrs.setObjectForKey($.NSNumber.numberWithDouble(-2.5), $.NSStrokeWidthAttributeName);
    attrs.setObjectForKey(para, $.NSParagraphStyleAttributeName);
    const ns = $(it.text);
    const margin = Math.round(w * 0.055);
    const box = $.NSMakeSize(w - margin * 2, h);
    const bounds = ns.boundingRectWithSizeOptionsAttributesContext(box, 1, attrs, $());
    const rect = $.NSMakeRect(margin, spec.marginV, w - margin * 2, Math.ceil(bounds.size.height));
    if (spec.box) {
      $.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.45).setFill;
      const pad = Math.round(spec.fontSize * 0.3);
      const bw = Math.ceil(bounds.size.width) + pad * 2;
      $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(
        $.NSMakeRect((w - bw) / 2, rect.origin.y - pad, bw, Math.ceil(bounds.size.height) + pad * 2),
        pad * 0.6, pad * 0.6).fill;
    }
    ns.drawWithRectOptionsAttributesContext(rect, 1, strokeAttrs, $());
    ns.drawWithRectOptionsAttributesContext(rect, 1, attrs, $());
    $.NSGraphicsContext.restoreGraphicsState;
    rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $())
       .writeToFileAtomically($(it.out), true);
  }
  return 'ok:' + spec.items.length;
}
''';

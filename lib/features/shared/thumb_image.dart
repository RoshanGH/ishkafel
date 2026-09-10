import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 缩略图：**按显示尺寸解码，不要整张原图**。
///
/// `Image.file` 默认按图片自己的分辨率解位图。落到盘上的缩略图是
/// 360×640（挑中的素材）或 270×480（封面、抽帧），一张解成 RGBA 是
/// 0.5~0.9MB；候选面板一屏几十张、审核页一次上百张，加起来是几十 MB，
/// 而每一张还白付一次全尺寸解码——真正画到屏幕上的只有一百来个逻辑像素宽
/// （挑中托盘里那格更只有 13pt）。
///
/// 这里按控件的**实际像素宽**解码（逻辑宽 × devicePixelRatio），画质与原来
/// 没有区别（目标尺寸就那么大），代价却少一个数量级。
///
/// [width] 给了就用它，省掉一层 [LayoutBuilder]；没给就现量。
class ThumbImage extends StatelessWidget {
  final String path;

  /// 逻辑宽度。null = 用 [LayoutBuilder] 量控件实际拿到多宽
  final double? width;

  final BoxFit fit;

  /// 读不出来时画什么（文件被删、格式坏）。不给就留白——
  /// 缩略图读不出不该炸掉整页
  final Widget Function(BuildContext context)? errorBuilder;

  const ThumbImage({
    super.key,
    required this.path,
    this.width,
    this.fit = BoxFit.cover,
    this.errorBuilder,
  });

  /// 解码宽度的下限：再小的格子也别解成马赛克
  static const _minDecodeWidth = 64;

  /// 上限：素材本来就是 1080 宽，解得比它还大没有意义
  static const _maxDecodeWidth = 1080;

  Widget _image(BuildContext context, double? logicalWidth) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;
    final target = logicalWidth == null || !logicalWidth.isFinite
        ? null
        : (logicalWidth * dpr)
            .round()
            .clamp(_minDecodeWidth, _maxDecodeWidth);
    return Image.file(
      File(path),
      fit: fit,
      cacheWidth: target,
      errorBuilder: (context, _, _) =>
          errorBuilder?.call(context) ?? const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fixed = width;
    if (fixed != null) return _image(context, fixed);
    return LayoutBuilder(
      builder: (context, box) => _image(
        context,
        box.hasBoundedWidth
            ? math.max(box.maxWidth, 1.0)
            // 宽度不受限（横向滚动里）就按高度推：素材是 9:16
            : (box.hasBoundedHeight ? box.maxHeight * 9 / 16 : null),
      ),
    );
  }
}

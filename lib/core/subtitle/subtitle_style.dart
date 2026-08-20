/// 重渲字幕的样式。
///
/// **为什么不克隆原片字幕的样式**：原片字幕烧在像素里，字体认不出、描边
/// 参数是连续值，仿到九成反而一眼「想仿没仿像」。真正决定观感的是位置和
/// 字号——同一句话前半句在原片镜头、后半句在替换镜头上，两行字高度差出
/// 几十像素才是穿帮。所以这里只开三个旋钮：位置、字号、配色预设；
/// 字体统一用系统中文黑体这一族，大大方方。
enum SubtitlePreset {
  /// 白字黑描边（短视频最常见的一族）
  whiteOutline,

  /// 白字 + 半透明黑底条（画面亮、杂的场景更稳）
  whiteBox,

  /// 黄字黑描边
  yellowOutline,

  /// 毛玻璃遮罩：字幕背后的一块**画面**被局部模糊——不是黑条，
  /// 是磨砂玻璃（用户点名要的形态）。模糊发生在 ffmpeg 侧
  /// （对文本框区域 boxblur），渲染层只负责给出文本框
  blurBox,
}

class SubtitleStyle {
  /// 字幕基线距**画面底部**的比例（0~1）。0.22 ≈ 竖屏底部安全区上沿
  final double bottomRatio;

  /// 字号占画面**高度**的比例。0.034 在 1920 高下约 65px——与示范原片
  /// （滴露样张）的字幕实测大小对齐；0.042 那档真机对比后偏大
  final double fontRatio;

  final SubtitlePreset preset;

  /// 自定义字色（RRGGBB 十六进制，不带 #）。null = 用预设自己的颜色。
  /// 编导台的六色选择走这里，preset 只决定描边/底条形态
  final String? colorHex;

  const SubtitleStyle({
    this.bottomRatio = 0.22,
    this.fontRatio = 0.034,
    this.preset = SubtitlePreset.whiteOutline,
    this.colorHex,
  });

  /// 开箱即用的默认样式
  static const standard = SubtitleStyle();

  Map<String, dynamic> toJson() => {
        'bottomRatio': bottomRatio,
        'fontRatio': fontRatio,
        'preset': preset.name,
        if (colorHex != null) 'colorHex': colorHex,
      };

  /// 宽松解析：字段缺失或认不出一律退回默认值——样式坏了不该让任务打不开
  static SubtitleStyle fromJson(Object? raw) {
    if (raw is! Map) return standard;
    final bottom = raw['bottomRatio'];
    final font = raw['fontRatio'];
    final preset = raw['preset'];
    return SubtitleStyle(
      bottomRatio: bottom is num && bottom > 0 && bottom < 1
          ? bottom.toDouble()
          : standard.bottomRatio,
      fontRatio: font is num && font > 0 && font < 0.5
          ? font.toDouble()
          : standard.fontRatio,
      preset: SubtitlePreset.values
              .where((p) => p.name == preset)
              .firstOrNull ??
          standard.preset,
      colorHex: raw['colorHex'] is String &&
              RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(raw['colorHex'] as String)
          ? raw['colorHex'] as String
          : null,
    );
  }

  /// 进渲染缓存指纹：样式一变，旧切片就不该再命中。
  /// 末尾的 v 是**渲染实现版本**——画法本身改了（比如描边从一遍画改成
  /// 两遍画）参数却没变时，靠它把旧图旧切片一并作废
  String get fingerprint =>
      'sub:${bottomRatio.toStringAsFixed(3)}:${fontRatio.toStringAsFixed(3)}'
      ':${preset.name}:${colorHex ?? '-'}:v4';
}

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
}

class SubtitleStyle {
  /// 字幕基线距**画面底部**的比例（0~1）。0.22 ≈ 竖屏底部安全区上沿
  final double bottomRatio;

  /// 字号占画面**高度**的比例。0.042 在 1920 高下约 80px——
  /// 投放类竖屏成片的常见档位
  final double fontRatio;

  final SubtitlePreset preset;

  const SubtitleStyle({
    this.bottomRatio = 0.22,
    this.fontRatio = 0.042,
    this.preset = SubtitlePreset.whiteOutline,
  });

  /// 开箱即用的默认样式
  static const standard = SubtitleStyle();

  Map<String, dynamic> toJson() => {
        'bottomRatio': bottomRatio,
        'fontRatio': fontRatio,
        'preset': preset.name,
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
    );
  }

  /// 进渲染缓存指纹：样式一变，旧切片就不该再命中
  String get fingerprint =>
      'sub:${bottomRatio.toStringAsFixed(3)}:${fontRatio.toStringAsFixed(3)}'
      ':${preset.name}';
}

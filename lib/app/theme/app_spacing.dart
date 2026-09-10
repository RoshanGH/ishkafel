/// 间距与圆角 token（4pt 网格）
///
/// CLAUDE.md 的设计标准要求「精致的间距系统（4pt 网格）」。改造前全项目
/// 有 91 处内联数字、并混用 3/9/10/14 这类不在网格上的值，视觉节奏是散的。
/// 所有新增 UI 一律取用这里的常量；`test/app/theme/app_spacing_test.dart`
/// 会守住「每个间距都是 4 的倍数」这条性质，防止再次漂移。
abstract final class AppSpacing {
  /// 4 — 最小间隙：图标与文字之间、密集信息的行内间距
  static const xs = 4.0;

  /// 8 — 常规间隙：卡片内元素之间、按钮内边距
  static const sm = 8.0;

  /// 12 — 分组间隙：同一卡片内不同信息组之间
  static const md = 12.0;

  /// 16 — 区块间隙：卡片之间、面板内边距
  static const lg = 16.0;

  /// 24 — 大区块间隙：面板之间
  static const xl = 24.0;

  /// 32 — 页面级留白
  static const xxl = 32.0;

  /// 所有间距值（供网格校验测试与设计走查使用）
  static const all = <double>[xs, sm, md, lg, xl, xxl];
}

/// 圆角 token
///
/// 遵循 Apple HIG「克制的圆角」：控件用小圆角，卡片用中圆角，
/// 浮层用大圆角；时间线上的块体不用圆角（帧对齐的边界需要锐利可辨）。
abstract final class AppRadius {
  /// 4 — 徽标、chip
  static const xs = 4.0;

  /// 6 — 按钮、输入框
  static const sm = 6.0;

  /// 8 — 卡片
  static const md = 8.0;

  /// 12 — 浮层、对话框
  static const lg = 12.0;

  /// 全圆（胶囊）：徽标、开关、进度条端头。
  /// 写 999 是老办法，但散在几十处就没人知道它是「刻意的全圆」
  /// 还是「随手打的一个大数」
  static const pill = 999.0;

  /// 全部档位（供阶梯校验测试使用）
  static const all = <double>[xs, sm, md, lg, pill];
}

/// 描边宽度 token
abstract final class AppStroke {
  /// 1 — 常规分隔线与描边
  static const hairline = 1.0;

  /// 2 — 选中态强调描边
  static const emphasis = 2.0;
}

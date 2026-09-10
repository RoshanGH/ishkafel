import 'package:flutter/material.dart';

/// HIG 暗色色板（值来源：项目 CLAUDE.md 设计标准）
abstract final class AppColors {
  // 五层地基，**明度是拉开的**。
  //
  // 2026-09-10 真机采样：右栏底色和页面背景都是 #202022（一模一样），
  // 卡片只比它亮 7 级、时间线只暗 4 级——整个界面挤在 11 级灰里，
  // 眼睛分不出哪一块是哪一块，看着就是糊的一片。产品负责人的话是
  // 「现在太不好看了」。
  //
  // 现在的阶梯（相对亮度递增）：
  //   剧场 5 → 页面 11 → 面板 23 → 浮起 32 → 卡片 42
  // 每一跳都看得出来，同时整体仍然是深色、不刺眼。

  /// 窗口地面。所有面板都浮在它上面
  static const background = Color(0xFF0B0B0D);

  /// 面板：顶栏、底栏、左栏这类贴着地面的一层
  static const surface = Color(0xFF17171A);

  /// 浮起的一层：右栏、对话框、浮层
  static const surfaceRaised = Color(0xFF202024);

  /// 卡片：浮在面板之上的块
  static const surfaceCard = Color(0xFF2A2A30);

  /// 分隔线与描边。白 11%——9% 在拉开层次之后显得太虚
  static const border = Color(0x1CFFFFFF);
  static const accentBlue = Color(0xFF0A84FF);
  /// accentBlue 的高亮变体：用于 accentBlue 半透明底上的文字（如标签 chip），
  /// 保证在深色 tint 底上的对比度。
  static const accentBlueLight = Color(0xFF64A8FF);
  static const green = Color(0xFF30D158);
  static const orange = Color(0xFFFF9F0A);
  static const red = Color(0xFFFF453A);
  static const purple = Color(0xFFBF5AF2);
  static const textPrimary = Color(0xFFF2F2F7);

  /// 次要文字。**比 macOS 系统的 secondaryLabel 亮**，理由见
  /// [textTertiary]：三级都要读得清，就得整体上移一档，
  /// 否则次要和三级会糊成一个亮度。
  static const textSecondary = Color(0xFFAEAEB6);

  /// 三级文字（说明、单位、时间码旁注）。
  ///
  /// 原来是 #636366（照抄 macOS 的 tertiaryLabel），在卡片底上对比度只有
  /// 2.33:1——WCAG AA 对正文要求 4.5:1。苹果自己的 tertiaryLabel 那么淡是
  /// 因为它只用来画 disabled 和装饰，而这个 app 拿它写「要读的说明」，
  /// 全项目两百多处（2026-09-09 设计走查：设置页底部那段说明几乎看不见）。
  /// 字号本来就压到了 10–11px，对比度再不够就是在费眼。
  ///
  /// 守这条性质的是 `test/app/theme/text_contrast_test.dart`，不是这个数值。
  static const textTertiary = Color(0xFF949499);

  /// 播放器舞台底色：视频画面区域背后的纯黑背景，与其余暗色层级区分，
  /// 让内容（画面/占位图标）在舞台内保持最高对比度。
  static const stageBackground = Color(0xFF000000);

  /// 容器上边缘那道**高光**：白 6%，只画一像素。
  ///
  /// macOS 里几乎每个浮起的面板都有它——光从上方来，上沿被照亮一线。
  /// 少了它，深色块就是一片死板的纯色；有了它，层与层之间立刻分得开、
  /// 也有了「材质」（2026-09-10 走查）。
  static const topHighlight = Color(0x0FFFFFFF);

  /// 中栏舞台区的地面：比全局背景再沉一级，让预览区从两侧工作栏里
  /// 「凹」下去成为剧场——预览是主角，视觉重量要给它
  static const stageWell = Color(0xFF050507);

  /// 预览画面的边。**比普通描边亮**：画面本身常常是纯黑（夜景、黑场、
  /// 还没开播的占位），舞台底色也接近黑，白 9% 的 [border] 压在这两层黑
  /// 中间等于看不见——人看不出画幅到哪儿为止（2026-09-09 设计走查：
  /// 编导台那块占位画面完全融进背景）。
  static const stageEdge = Color(0x2EFFFFFF); // 白 18%

  /// 悬停反馈：白 4%，暗色下可感知但不喧宾
  static const hover = Color(0x0AFFFFFF);
}

/// 上沿一线高光，做成**渐变**而不是描边。
///
/// Flutter 不允许「有圆角时四边异色」（`A borderRadius can only be given
/// on borders with uniform colors`），所以高光不能用 Border(top:) 画。
/// 渐变反而更自然：顶部一线亮起、很快回到底色，像光落在一个有厚度的面上。
///
/// macOS 里几乎每个浮起的面板都有它。少了它，深色块就是一片死板的纯色；
/// 有了它，层与层之间分得开，也才有「材质」而不只是「颜色」
/// （2026-09-10 走查，产品负责人原话「现在太不好看了」）。
LinearGradient topLit(Color base) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color.alphaBlend(AppColors.topHighlight, base), base],
      stops: const [0, 0.06],
    );

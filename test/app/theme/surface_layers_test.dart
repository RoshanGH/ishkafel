import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_colors.dart';

/// **层与层之间要看得出来。**
///
/// 2026-09-10 真机采样：右栏底色和页面背景都是 #202022（一模一样），
/// 卡片只比它亮 7 级、时间线只暗 4 级——整个界面挤在 11 级灰里，
/// 眼睛分不出哪一块是哪一块。产品负责人的原话：「现在太不好看了」。
///
/// 守的是**性质**：相邻两层必须有肉眼分得出的明度差。换配色可以，
/// 糊成一片不行。
double _lum(Color c) =>
    0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

/// 8 位灰度下的差值，方便按「差几级」讲话
double _steps(Color a, Color b) => ((_lum(a) - _lum(b)) * 255).abs();

void main() {
  test('五层地基从沉到浮，一层比一层亮', () {
    final ladder = [
      AppColors.stageWell,
      AppColors.background,
      AppColors.surface,
      AppColors.surfaceRaised,
      AppColors.surfaceCard,
    ];

    for (var i = 1; i < ladder.length; i++) {
      expect(_lum(ladder[i]), greaterThan(_lum(ladder[i - 1])),
          reason: '第 $i 层没有比上一层亮，阶梯是乱的');
    }
  });

  test('相邻两层至少差 6 级——再近就分不出了', () {
    final pairs = <(String, Color, Color)>[
      ('剧场 → 页面', AppColors.stageWell, AppColors.background),
      ('页面 → 面板', AppColors.background, AppColors.surface),
      ('面板 → 浮起', AppColors.surface, AppColors.surfaceRaised),
      ('浮起 → 卡片', AppColors.surfaceRaised, AppColors.surfaceCard),
    ];

    final tooClose = [
      for (final (name, a, b) in pairs)
        if (_steps(a, b) < 6) '$name 只差 ${_steps(a, b).toStringAsFixed(1)} 级',
    ];

    expect(tooClose, isEmpty,
        reason: '这几层糊在一起了：\n${tooClose.join('\n')}');
  });

  test('整体仍然是深色——不能为了分层把界面拉白', () {
    expect(_lum(AppColors.surfaceCard), lessThan(0.25),
        reason: '最亮的一层也该是深色，这是个盯着看一天的工具');
  });

  test('上沿高光够淡，只是一线光，不是一条白边', () {
    expect(AppColors.topHighlight.a, lessThan(0.12));
    expect(AppColors.topHighlight.a, greaterThan(0.03));
  });
}

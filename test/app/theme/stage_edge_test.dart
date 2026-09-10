import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/app/theme/app_colors.dart';

import 'text_contrast_test.dart' show contrast;

/// **画面的边要在「黑压黑」上还看得见。**
///
/// 2026-09-09 设计走查：编导台那块还没内容的预览画面完全融进了背景——
/// 画面本身是纯黑，舞台底色也接近黑，中间那条白 9% 的普通描边等于不存在，
/// 人看不出画幅到哪儿为止。
void main() {
  test('舞台边比普通描边亮得多', () {
    expect(AppColors.stageEdge.a, greaterThan(AppColors.border.a * 1.5),
        reason: '普通描边是给「面板压面板」用的，压不住「黑画面压黑舞台」');
  });

  test('压在纯黑画面上分得出来', () {
    // 边本身是半透明白叠在纯黑上，等效亮度按 alpha 估
    final onBlack = AppColors.stageEdge.a;

    expect(onBlack, greaterThan(0.15),
        reason: '再淡就看不出画幅边界了');
    expect(onBlack, lessThan(0.35),
        reason: '太亮会变成一道抢眼的白框，喧宾夺主');
  });

  test('舞台底色确实比页面背景更沉——画面要从里面凹出来', () {
    expect(contrast(AppColors.background, AppColors.stageBackground),
        greaterThan(contrast(AppColors.stageWell, AppColors.stageBackground)),
        reason: 'stageWell 该比全局背景更接近画面的黑');
  });
}

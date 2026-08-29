import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/ui_action.dart';

/// 可视模式和写锁**打架**——验收 Agent 一针见血：
///
/// > 可视要求界面停在这个任务上，写入要求界面不能停在这个任务上。
/// > 整条流水线里最该让人看见的一步（提交方案，成片长什么样就是这一步定的），
/// > 恰恰因为「人在看」而做不了。
///
/// 以前给的出路是「让界面挪开」——那等于让人别看。
/// 正确的解法是**委派**：界面占着锁就请界面去做，人眼看着方案落到时间线上。
/// 新建任务一直是这么做的（`wizard.*`），提交方案漏了。
void main() {
  test('提交方案是一个可以委派给界面的动作', () {
    expect(UiAction.parse('plans.apply'), UiAction.plansApply);
  });

  test('这个动作有人话说明——横幅上要显示它', () {
    expect(UiAction.plansApply.label, isNotEmpty);
    expect(UiAction.plansApply.label, contains('方案'));
  });

  test('认不出的动作还是返回 null，不瞎猜', () {
    expect(UiAction.parse('plans.applyx'), isNull);
  });
}

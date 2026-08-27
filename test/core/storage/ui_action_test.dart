import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/storage/ui_action.dart';

/// Agent 能让界面做哪些**动作**。
///
/// 这是「可视模式」真正的形态：不是 Agent 在后台改完数据、界面事后显示，
/// 而是**界面真的被操作了一遍**——向导弹出来、字段填上、按钮被点。
/// 数据由界面写，走的是人走的同一条路，所以不会出现「演的和真的不一样」。
///
/// 为什么值得这么做：严格交付的活儿，人要看得见每一步才敢信。前面走错
/// 一两步，后面差很远——只有当着人的面稳稳跑过很多次，人才会放心用静默。
void main() {
  group('动作清单', () {
    test('每个动作都有人话说明——手册和界面横幅都要用它', () {
      for (final a in UiAction.values) {
        expect(a.label, isNotEmpty, reason: '${a.name} 没有说明');
      }
    });

    test('按名字认得回来', () {
      expect(UiAction.parse('wizard.open'), UiAction.wizardOpen);
      expect(UiAction.parse('wizard.submit'), UiAction.wizardSubmit);
    });

    test('认不出的返回 null，不猜——猜错会点到别的按钮上', () {
      expect(UiAction.parse('wizard.随便写'), isNull);
      expect(UiAction.parse(''), isNull);
    });

    test('新建任务这条线该有的动作都在', () {
      final names = UiAction.values.map((a) => a.wire).toSet();
      expect(names, containsAll(const [
        'wizard.open',
        'wizard.fill',
        'wizard.submit',
        'wizard.cancel',
      ]));
    });
  });

  group('新建向导的参数', () {
    test('选哪条线：脚本成片 / 成片翻新 / 空白拼片', () {
      expect(WizardMode.parse('script'), WizardMode.script);
      expect(WizardMode.parse('renew'), WizardMode.renew);
      expect(WizardMode.parse('blank'), WizardMode.blank);
      expect(WizardMode.parse('乱写'), isNull);
    });

    test('成片翻新必须给原片路径——没有原片这条线走不通', () {
      final issues = validateWizardFill(
          mode: WizardMode.renew, filePath: null, tagGroupIds: const [1]);
      expect(issues, isNotEmpty);
      expect(issues.first, contains('原片'));
    });

    test('脚本成片不需要原片', () {
      expect(
          validateWizardFill(
              mode: WizardMode.script, filePath: null, tagGroupIds: const [1]),
          isEmpty);
    });

    test('一个标签组都不选：拒绝并说清后果', () {
      final issues = validateWizardFill(
          mode: WizardMode.script, filePath: null, tagGroupIds: const []);
      expect(issues, isNotEmpty);
      expect(issues.first, contains('标签组'));
    });

    test('给了不存在的原片路径：当场拒绝，不要等建到一半才发现', () {
      final issues = validateWizardFill(
          mode: WizardMode.renew,
          filePath: '/根本没有这个文件.mp4',
          tagGroupIds: const [1]);
      expect(issues, isNotEmpty);
      expect(issues.first, contains('找不到'));
    });
  });
}

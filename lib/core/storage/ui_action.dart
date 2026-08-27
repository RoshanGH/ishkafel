import 'dart:io';

/// Agent 能让界面执行的**动作**清单。
///
/// 这是「可视模式」真正的形态：不是 Agent 在后台把数据改完、界面事后
/// 显示结果，而是**界面真的被操作了一遍**——向导弹出来、字段填上、
/// 按钮被点。数据由界面写，走的是人走的同一条路。
///
/// 为什么不做成「演示」：演出来的东西迟早会和真实行为对不上。这个项目
/// 已经因为「同一个东西两处算」栽过三次（原声静音、配音过期误报、
/// 划词时长被平摊）。界面演一套、CLI 写一套，是同一个毛病的更大版本。
///
/// 为什么值得做：严格交付的活儿，人要看得见每一步才敢信。前面走错一两步，
/// 后面差很远——只有当着人的面稳稳跑过很多次，人才会放心切到静默模式。
///
/// 动作走 [AgentRequest] 通道：CLI 下单、界面执行、回执配对。
enum UiAction {
  /// 打开「新建任务」向导，并选好走哪条线
  wizardOpen('wizard.open', '打开新建任务'),

  /// 往向导里填：原片、标签组、打标约束、项目
  wizardFill('wizard.fill', '填新建任务的表单'),

  /// 点「创建」
  wizardSubmit('wizard.submit', '创建任务'),

  /// 关掉向导（人喊停、或者参数不合格时收手）
  wizardCancel('wizard.cancel', '取消新建任务');

  const UiAction(this.wire, this.label);

  /// 传输用的名字（CLI 和界面共用这一份，不各写各的字符串）
  final String wire;

  /// 人话说明：手册里列它，界面横幅上也显示它
  final String label;

  static UiAction? parse(String? name) {
    for (final a in UiAction.values) {
      if (a.wire == name) return a;
    }
    return null;
  }
}

/// 新建任务走哪条线。与手册里那张「两条线」的表一一对应
enum WizardMode {
  /// 脚本成片：从台词造一条新片，不需要原片
  script('script'),

  /// 成片翻新：拿一条现成的片子换画面
  renew('renew'),

  /// 空白拼片：翻新线的旁支，没有台词与配音
  blank('blank');

  const WizardMode(this.wire);
  final String wire;

  static WizardMode? parse(String? name) {
    for (final m in WizardMode.values) {
      if (m.wire == name) return m;
    }
    return null;
  }
}

/// 校验要填进向导的东西。**当场拒绝**，别等建到一半才发现。
///
/// 界面上这些是靠「按钮置灰」拦住的，Agent 那头没有按钮挡着，
/// 所以规则要在这里说清并给出人话原因。
List<String> validateWizardFill({
  required WizardMode mode,
  required String? filePath,
  required List<int> tagGroupIds,
}) {
  final issues = <String>[];
  if (mode == WizardMode.renew) {
    if (filePath == null || filePath.trim().isEmpty) {
      issues.add('成片翻新要给原片（--file）——这条线就是拿现成的片子换画面，'
          '没有原片走不通。想从零做一条就用 script 那条线');
    } else if (!File(filePath).existsSync()) {
      issues.add('找不到这个原片：$filePath');
    }
  }
  if (tagGroupIds.isEmpty) {
    // 这条静默失败链在真机上撞过：没有标签组 → AI 打不出标签 →
    // 后面挑素材时没有标签可用，而那时已经走了好几步
    issues.add('一个标签组都没选。标签组是打标的受控词表，没有它 AI 打不出标签，'
        '后面挑素材时就没有标签可检索。用 ishkafel tag-groups 看有哪些');
  }
  return issues;
}

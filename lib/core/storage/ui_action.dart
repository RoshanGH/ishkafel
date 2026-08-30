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
  wizardCancel('wizard.cancel', '取消新建任务'),

  /// 提交替换方案。
  ///
  /// **为什么要能委派**：可视模式要求界面停在这个任务上，而写入要求界面
  /// 不能停在这个任务上（它占着锁）——于是整条流水线里最该让人看见的一步，
  /// 恰恰因为「人在看」而做不了。以前给的出路是「让界面挪开」，那等于让人
  /// 别看。委派给界面去做，人就能眼看着三条方案一条条落到时间线上。
  plansApply('plans.apply', '提交替换方案'),

  /// 打开导出对话框，参数填好，**最后那一下由人点**。
  ///
  /// 和提交方案同一个死结：可视模式要求界面停在这个任务上，而导出要求
  /// 界面不能停在这个任务上——于是人最想看着的一步（分钟级、直接产出
  /// 交付物）恰恰因为「人在看」而做不了。
  ///
  /// 但和提交方案不一样：导出跑几分钟，硬塞进回执通道不合适；而且它
  /// **花钱花时间**——人在旁边时让他确认一下反而是对的。所以委派的是
  /// 「打开、填好」，不是「一路点到底」。
  exportOpen('export.open', '打开导出');

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

/// 新建任务要建成什么。
///
/// **两条线、四种起点**，这里的三个值是其中三种（脚本成片的「从参考片提取
/// 台词」发生在编导台里，不在建任务这一步）：
///
/// | | 有原片 | 没有原片 |
/// |---|---|---|
/// | 替换裂变 | [replace] | [blank] |
/// | 脚本成片 | （进编导台后传参考片） | [script] |
enum WizardMode {
  /// 脚本成片：从台词造一条新片，不需要原片
  script('script'),

  /// 替换裂变 · 有原片：拿一条现成的片子换画面
  replace('replace'),

  /// 替换裂变 · 没有原片：手动排位置、每个位置挑素材拼起来，没有台词与配音
  blank('blank');

  const WizardMode(this.wire);
  final String wire;

  /// `renew` 是 [replace] 的旧名（那时这条线还叫「成片翻新」）。
  /// 认它是为了不让已经写好的 Agent 脚本一夜之间失效
  static const Map<String, WizardMode> _legacy = {'renew': WizardMode.replace};

  static WizardMode? parse(String? name) {
    for (final m in WizardMode.values) {
      if (m.wire == name) return m;
    }
    return _legacy[name];
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
  if (mode == WizardMode.replace) {
    if (filePath == null || filePath.trim().isEmpty) {
      issues.add('替换裂变要给原片（--file）——这条线就是拿现成的片子换画面，'
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

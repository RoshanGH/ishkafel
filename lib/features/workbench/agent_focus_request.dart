/// 界面该跟到哪儿——**给工作台看的那一份**。
///
/// 与 `AgentFocus`（盘上的原始记录）分开：那一份是给全软件用的通用结构，
/// 这一份只留工作台真正用得上的几样，并且把「该不该切到候选面板」这种
/// 判断先算好——各个组件各判一遍，迟早判得不一样。
class AgentFocusRequest {
  /// 第几步。同一步重复上报不重跟，否则选中框会闪
  final int step;

  final int? unitIndex;
  final int? shotIndex;

  /// 这一步是不是在挑素材——是就把右栏切到「替换素材」，
  /// 让人看得见它在挑什么
  final bool wantsCandidates;

  const AgentFocusRequest({
    required this.step,
    this.unitIndex,
    this.shotIndex,
    this.wantsCandidates = false,
  });
}

/// 播报条上要点明「在哪条任务上干活」。
///
/// 只说「Agent 正在操作」是不够的：人正看着 #9，动的可能是 #11。
/// 验收 Agent 也撞到过——它自己没跑命令，界面却在动，
/// 一度以为是「界面跟错任务」，差点报成 bug。
///
/// 总是报出来而不是「不一致时才报」：全局播报层拿不到「人正在看哪一页」，
/// 而人自己知道自己在看什么——把事实摆出来就够了。
///
/// 返回 null = 这活儿不属于任何一条任务（新建任务、导入）。
String? broadcastScopeLabel({required int? actingTaskSeq}) =>
    actingTaskSeq == null ? null : '#$actingTaskSeq';

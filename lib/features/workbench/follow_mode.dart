import 'agent_focus_request.dart';

/// 跟随时要不要顺手切到「镜头替换」。
///
/// **为什么要切**：播报说「正在给 U2S3 挑素材」，而右栏写着「这个台词语义
/// 单元保留原片，要替换的话先在上方选择模式」——两句话打架。而这是最常见的
/// 场景：任何一条新任务第一次挑素材时都处在这个状态，人第一次看 Agent 干活
/// 看到的就是它。
///
/// 人自己要给某一镜挑素材，第一步就是点「镜头替换」。跟随走同一条路。
///
/// **什么时候不切**：只是看看（没在挑素材）、挑的是整段（没指镜头）、
/// 这个单元切不出镜头、已经是镜头替换了——最后一条尤其要紧，
/// 切一次会清空这个单元已经选好的东西。
bool shouldEnterShotMode(
  AgentFocusRequest focus, {
  required bool canUsePerShot,
  required bool alreadyPerShot,
}) =>
    focus.wantsCandidates &&
    focus.shotIndex != null &&
    canUsePerShot &&
    !alreadyPerShot;

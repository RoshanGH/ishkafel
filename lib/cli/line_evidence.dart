import '../core/script/script_doc.dart';

/// 这一镜在成片里**真正会出现的那一帧**落在素材的哪一刻。
///
/// 不是素材的第 0 帧：这一镜是从 [LineShot.trimStartMs] 开始取的，
/// 人在界面上看到的缩略图也是取段之后的画面。给错了帧，Agent 看到的
/// 就不是成片里的东西，跟人讨论时对不上。
///
/// 取**这一段偏前的位置**而不是正中间：一镜常有运动，偏前的画面更接近
/// 「切进来时看到的第一眼」，也是人判断「这一镜对不对」时看的那一眼。
int evidenceFrameAtMs(LineShot shot) {
  final src = shot.durationMs;
  final start = shot.trimStartMs;
  // 用量按素材时间算：倍速改变的是成片时长，不改变素材里的时刻
  final useMs = ((shot.allocMs ?? 0) * shot.speed).round();
  final into = useMs > 0 ? (useMs * 0.25).round() : 500;
  var at = start + (into < 500 ? into : 500);
  if (src != null && src > 0) {
    // 别取到素材外面去：贴着末尾的取段起点会算出越界的时刻
    final maxAt = src - 100;
    if (at > maxAt) at = maxAt < start ? (start < src ? start : src ~/ 2) : maxAt;
  }
  return at < 0 ? 0 : at;
}

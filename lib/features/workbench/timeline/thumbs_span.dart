import '../../../core/models/semantic_unit.dart';

/// 胶片条（画面缩略图轨）铺在**原片**上覆盖多长。
///
/// 缩略图是从原片按等间隔抽出来的，所以它们代表的是「原片 0 ~ 原片时长」。
/// 不能拿 `geometry.durationMs`（**成片**总长）去等分——手动加的单元在原片上
/// 不存在，它占的那段时间里没有任何原片画面可放，算进去整条胶片条就整体
/// 压扁、和上面的单元块全部对不齐（2026-09-07 真机 bug）。
///
/// 返回 0 表示这条任务没有原片（空白任务，或全是手加的单元）——那时整条
/// 胶片条不该画。
int sourceSpanMs(List<SemanticUnit> units) {
  var max = 0;
  for (final u in units) {
    // 手加的单元原片上没有它，它的 startMs/endMs 只是时间线上的占位
    if (!u.hasSource) continue;
    if (u.endMs > max) max = u.endMs;
  }
  return max;
}

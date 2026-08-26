import 'script_doc.dart';

/// 播放头落在**哪一行的哪一镜**（成片时间轴，毫秒）。
///
/// 存在理由是一条交互：**播放到哪，就把那一镜的操作栏展开**。人看着片子
/// 播过去，手边就是那一镜的取段、速度、原声——不用先暂停、再找到那一行、
/// 再点开。
///
/// [lineStarts] 是这一版轨道里每一行的起点（见 `ScriptPlanResult`）。
/// 没进预览的行不在里面，也就不该被算进来——它在轨道上根本没有位置。
///
/// 返回 `(行下标, 镜下标)`；那一行还没有镜头时镜下标为 null；
/// 一条都没铺时返回 null。
(int, int?)? shotAt(ScriptDoc doc, Map<int, int> lineStarts, int ms) {
  int? lineIndex;
  var bestStart = -1;
  for (final e in lineStarts.entries) {
    if (e.value <= ms && e.value > bestStart) {
      bestStart = e.value;
      lineIndex = e.key;
    }
  }
  // 播放头还在第一行之前（或时间为负）：算作最靠前的那一行
  if (lineIndex == null) {
    for (final e in lineStarts.entries) {
      if (bestStart < 0 || e.value < bestStart) {
        bestStart = e.value;
        lineIndex = e.key;
      }
    }
  }
  if (lineIndex == null || lineIndex >= doc.lines.length) return null;

  final shots = doc.lines[lineIndex].shots;
  if (shots.isEmpty) return (lineIndex, null);

  var at = bestStart;
  int? last;
  for (var j = 0; j < shots.length; j++) {
    final alloc = shots[j].allocMs;
    // 时长还没算出来的镜跳过：它在轨道上没有位置，把播放头卡在它上面
    // 只会让人对着一个空面板
    if (alloc == null || alloc <= 0) continue;
    last = j;
    if (ms < at + alloc) return (lineIndex, j);
    at += alloc;
  }
  // 走到行尾（或超过片尾）：停在最后一镜。播完那一刻把面板收起来，
  // 人正想改的东西就没了
  return (lineIndex, last);
}

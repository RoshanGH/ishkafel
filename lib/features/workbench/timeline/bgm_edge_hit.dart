/// 配乐段落的哪一头
enum BgmEdge { start, end }

/// 手柄的命中半径。比视觉上那条线宽不少——边界拖拽是高频操作，
/// 差几像素点不中会让人反复试
const double bgmEdgeHitRadius = 6;

/// 光标落在这一段的哪个手柄上；落在中间（那里是「点开换曲子」）返回 null。
///
/// **块体很窄时两个手柄会重叠**：那时按中点劈开，左半边算左、右半边算右——
/// 总比两个都点不中强。
BgmEdge? bgmEdgeAt({
  required double dx,
  required double left,
  required double right,
}) {
  if (dx < left - bgmEdgeHitRadius || dx > right + bgmEdgeHitRadius) {
    return null;
  }
  if (right - left <= bgmEdgeHitRadius * 2) {
    return dx < (left + right) / 2 ? BgmEdge.start : BgmEdge.end;
  }
  if (dx <= left + bgmEdgeHitRadius) return BgmEdge.start;
  if (dx >= right - bgmEdgeHitRadius) return BgmEdge.end;
  return null;
}

/// 删除按钮的边长
const double bgmDeleteSize = 14;

/// 块体至少要这么宽才画删除按钮。再窄的话按钮会盖住整段，点哪儿都是删
const double bgmDeleteMinWidth = 40;

/// 光标是不是点在这一段的删除按钮上。
///
/// **按钮摆在右上角、且往里让开拖拽手柄**：拖边界改长度是高频操作，被删除
/// 按钮抢走点击会误删——那是不可逆的。
///
/// 此前删一段要「点开素材库浮层 → 等它加载完 → 点移除」，太重了。
bool hitsBgmDelete({
  required double dx,
  required double dy,
  required double left,
  required double right,
  required double top,
  required double bottom,
}) {
  if (right - left < bgmDeleteMinWidth) return false;
  final boxRight = right - bgmEdgeHitRadius;
  final boxLeft = boxRight - bgmDeleteSize;
  final boxTop = top + 2;
  return dx >= boxLeft &&
      dx <= boxRight &&
      dy >= boxTop &&
      dy <= boxTop + bgmDeleteSize;
}

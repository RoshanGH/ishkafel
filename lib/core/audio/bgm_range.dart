import 'dart:math' as math;

import '../models/semantic_unit.dart';

/// 已经指不到东西了，为此崩掉整个时间线不值得。
int unitRangeMs(List<SemanticUnit> units, {required int from, required int to}) {
  if (units.isEmpty) return 0;
  final lo = math.max(0, math.min(from, to));
  final hi = math.min(units.length - 1, math.max(from, to));
  if (lo > hi) return 0;
  return units[hi].endMs - units[lo].startMs;
}

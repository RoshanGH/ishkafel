/// 被整体替换的单元在成片里有多长。
///
/// 时间线画的是**原片**的切分，而整体替换会让这一段变长或变短、后面所有单元
/// 跟着挪。时间线本身不变形（它是切分的载体），但至少要把「这一段成片里是
/// 多长」写出来，否则用户不知道成片总长已经变了。
String? replacedDurationLabel({required int sourceMs, int? composedMs}) {
  if (composedMs == null || composedMs <= 0) return null;
  // 差得可以忽略时不标：候选和原段落时长本来就常有几十毫秒出入
  if ((composedMs - sourceMs).abs() <= 100) return null;
  String s(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';
  return '${s(sourceMs)} → ${s(composedMs)}';
}

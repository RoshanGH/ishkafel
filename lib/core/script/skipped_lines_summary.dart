/// 「这几行为什么没进预览」——一句话说清，别把同一个原因抄好几遍。
///
/// 2026-09-09 设计走查真机：四行台词都没配音，中栏就摞了四条橙字：
/// 「第 1 行未进预览：还没生成配音（配音时长是这一行的根）」
/// 「第 2 行未进预览：还没生成配音（配音时长是这一行的根）」…
/// 一模一样，只有行号不同。该省的从来不是行号，是重复的那句原因。
///
/// [skipped] 是「行下标（从 0 起）→ 原因」。输出按原因归堆，
/// 每堆的行号并成区间：`第 1–4 行未进预览：还没生成配音`。
String summarizeSkippedLines(Map<int, String> skipped) {
  if (skipped.isEmpty) return '';
  final byReason = <String, List<int>>{};
  for (final entry in skipped.entries) {
    (byReason[entry.value] ??= []).add(entry.key + 1);
  }
  return [
    for (final entry in byReason.entries)
      '${lineNumberRanges(entry.value)}未进预览：${entry.key}',
  ].join('\n');
}

/// 把行号并成人读的区间：`第 1–4 行`、`第 1、3 行`、`第 1–2、5 行`。
String lineNumberRanges(List<int> lines) => '第 ${numberRanges(lines)} 行';

/// 把单元下标（0 起）并成 `U2–U5`、`U1、U3`。
///
/// 四个还能一个个念，十个就不行了——「U2、U3、U4、U5、U6、U7…」
/// 是一串噪音，人要自己去数中间断没断。
String unitRanges(List<int> zeroBased) =>
    numberRanges([for (final i in zeroBased) i + 1], prefix: 'U');

/// 数字并区间的通用形式：`1–4`、`1、3`、`1–2、5`。
///
/// 连着的才并——`1、3` 并成 `1–3` 会把没出问题的 2 也算进去，
/// 那是在冤枉它。[prefix] 给每一段加个前缀（`U2–U5` 这种）。
String numberRanges(List<int> numbers, {String prefix = ''}) {
  final sorted = [...numbers]..sort();
  final parts = <String>[];
  var start = sorted.first;
  var prev = sorted.first;
  for (final n in sorted.skip(1)) {
    if (n == prev + 1) {
      prev = n;
      continue;
    }
    parts.add(_range(start, prev, prefix));
    start = n;
    prev = n;
  }
  parts.add(_range(start, prev, prefix));
  return parts.join('、');
}

String _range(int from, int to, String prefix) {
  if (from == to) return '$prefix$from';
  // 挨着的两个写成「1、2」比「1–2」读着顺
  if (to == from + 1) return '$prefix$from、$prefix$to';
  return '$prefix$from–$prefix$to';
}

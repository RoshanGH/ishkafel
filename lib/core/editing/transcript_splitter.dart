import 'package:characters/characters.dart';

import '../analysis/providers.dart';

/// 台词拆分：把一段台词按拆分点分成左右两段。
///
/// 两条路径：
/// - [splitAt]：台词仍等同于 ASR 逐句原文时，按句子时间戳精确分配（最准）
/// - [splitTextByRatio]：台词已不再等同于 ASR 原文（LLM 改写或用户手工
///   编辑过）时，只能按拆分点在单元时长中的比例切现有文本
class TranscriptSplitter {
  const TranscriptSplitter._();

  /// 句读边界字符：在这些字符**之后**切开最贴近用户对"一句台词"的直觉。
  /// 同时收中英文标点，因为 ASR/LLM 产出的台词两种标点都可能出现。
  static const _sentenceEnders = {
    '。', '！', '？', '；', '，', '、', '…', '：',
    '.', '!', '?', ';', ',', ':', '\n', //
  };

  /// 按句子中点归属拆分：句子中点 < splitMs 的归左段，其余归右段。
  static (String left, String right) splitAt(
      List<AsrSentence> sentences, int splitMs) {
    final left = StringBuffer();
    final right = StringBuffer();
    for (final s in sentences) {
      final mid = (s.startMs + s.endMs) / 2;
      if (mid < splitMs) {
        left.write(s.text);
      } else {
        right.write(s.text);
      }
    }
    return (left.toString(), right.toString());
  }

  /// 按比例把一段现有台词切成左右两段；[ratio] 为拆分点在单元时长中的占比。
  ///
  /// 保证 `left + right == text`（逐字无损）：用户手工编辑过的台词一个字都
  /// 不会丢，拆分后再合并回来即可复原原文。切点先按字素比例定位，再吸附到
  /// 窗口内最近的句读之后——台词天然以句为单位，落在句中会让两段读起来都
  /// 是断句。吸附**不以文本两端为候选**，避免把本可两分的台词吸成一空一满。
  ///
  /// 按字素（characters）而非 code unit 切分，emoji 等多码位字符不会被拦腰
  /// 截断成乱码。
  static (String left, String right) splitTextByRatio(
      String text, double ratio) {
    final chars = text.characters.toList();
    final n = chars.length;
    if (n == 0) return ('', '');

    final r = ratio.isNaN ? 0.5 : ratio.clamp(0.0, 1.0);
    final rawCut = (n * r).round().clamp(0, n);
    final cut = _snapToSentenceBoundary(chars, rawCut);

    return (chars.take(cut).join(), chars.skip(cut).join());
  }

  /// 把字素下标 [cut] 吸附到窗口内最近的句读边界（句读字符之后的位置）。
  /// 窗口取文本长度的四分之一（至少 4 个字素），避免把切点拉到离比例位置
  /// 很远的地方。窗口内无候选时原样返回。
  static int _snapToSentenceBoundary(List<String> chars, int cut) {
    final n = chars.length;
    final quarter = n ~/ 4;
    final window = quarter < 4 ? 4 : quarter;

    int? best;
    var bestDist = window + 1;
    // i 是"切点下标"，即 chars[i-1] 之后；i 取值 [1, n-1] 天然排除了两端
    for (var i = 1; i < n; i++) {
      if (!_sentenceEnders.contains(chars[i - 1])) continue;
      final d = (i - cut).abs();
      // 距离相等时取更靠右的候选（宁可多留给左段一句完整的话）
      if (d <= window && d <= bestDist) {
        best = i;
        bestDist = d;
      }
    }
    return best ?? cut;
  }
}

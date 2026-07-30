import '../analysis/providers.dart';

/// 台词拆分：把一组 ASR 句子按拆分点分配到左右两段。
///
/// 规则：句子中点 < splitMs 的句子归左段，其余归右段。
class TranscriptSplitter {
  const TranscriptSplitter._();

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
}

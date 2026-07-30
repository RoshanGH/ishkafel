import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/editing/transcript_splitter.dart';

const sentences = [
  AsrSentence(startMs: 0, endMs: 2000, text: '甲。'),
  AsrSentence(startMs: 2100, endMs: 4000, text: '乙。'),
  AsrSentence(startMs: 4100, endMs: 6000, text: '丙。'),
];

void main() {
  test('句子按中点归属拆分', () {
    final (l, r) = TranscriptSplitter.splitAt(sentences, 3000);
    expect(l, '甲。');
    expect(r, '乙。丙。');
  });

  test('拆分点在句子中点右侧时该句归左', () {
    final (l, r) = TranscriptSplitter.splitAt(sentences, 3200);
    expect(l, '甲。乙。');
    expect(r, '丙。');
  });

  test('空句子列表返回空串对', () {
    expect(TranscriptSplitter.splitAt(const [], 100), ('', ''));
  });
}

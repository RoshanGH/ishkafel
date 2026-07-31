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

  group('splitTextByRatio（按比例切分现有台词文本）', () {
    test('无句读时按字符比例切开，左右拼接等于原文', () {
      final (l, r) = TranscriptSplitter.splitTextByRatio('甲乙丙丁', 0.5);
      expect(l, '甲乙');
      expect(r, '丙丁');
    });

    test('切点吸附到最近的句读之后（贴合"一句话"的直觉）', () {
      // '第一句。第二句。' 共 8 字，比例 0.4 → 原始切点 3；窗口内最近的句读
      // 边界是 4（第一个"。"之后），应吸附过去
      final (l, r) = TranscriptSplitter.splitTextByRatio('第一句。第二句。', 0.4);
      expect(l, '第一句。');
      expect(r, '第二句。');
    });

    test('吸附不把任一侧吸空：文本两端不作为候选切点', () {
      // '一二三。' 唯一的句读在末尾，若允许吸到末尾会产出空的右段
      final (l, r) = TranscriptSplitter.splitTextByRatio('一二三。', 0.5);
      expect(l, '一二');
      expect(r, '三。');
    });

    test('比例被夹在 [0,1]；空串返回空串对', () {
      expect(TranscriptSplitter.splitTextByRatio('', 0.5), ('', ''));
      expect(TranscriptSplitter.splitTextByRatio('甲乙', -1), ('', '甲乙'));
      expect(TranscriptSplitter.splitTextByRatio('甲乙', 2), ('甲乙', ''));
    });

    test('不切开由多个码位组成的字素（emoji）', () {
      final (l, r) = TranscriptSplitter.splitTextByRatio('👨‍👩‍👧甲', 0.5);
      expect(l, '👨‍👩‍👧');
      expect(r, '甲');
    });
  });
}

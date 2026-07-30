import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';

void main() {
  const word1 = AsrWord(startMs: 40, endMs: 200, text: '第', confidence: 0.98);
  const word2 = AsrWord(startMs: 200, endMs: 400, text: '一');

  test('AsrWord 序列化往返一致（含 confidence）', () {
    expect(AsrWord.fromJson(word1.toJson()), word1);
  });

  test('AsrWord confidence 缺失时保持 null 且序列化往返一致', () {
    expect(word2.confidence, isNull);
    expect(AsrWord.fromJson(word2.toJson()), word2);
  });

  test('AsrSentence 序列化往返一致（含 words）', () {
    const sentence = AsrSentence(
      startMs: 40,
      endMs: 1500,
      text: '第一句。',
      words: [word1, word2],
    );
    final restored = AsrSentence.fromJson(sentence.toJson());
    expect(restored, sentence);
    expect(restored.words, [word1, word2]);
  });

  test('AsrSentence.fromJson 兼容 words 键缺失（回退空列表）', () {
    final restored = AsrSentence.fromJson(const {
      'startMs': 0,
      'endMs': 1000,
      'text': '无字级信息',
    });
    expect(restored.words, isEmpty);
    expect(
      restored,
      const AsrSentence(startMs: 0, endMs: 1000, text: '无字级信息'),
    );
  });

  test('AsrSentence 默认 words 为空列表', () {
    const sentence = AsrSentence(startMs: 0, endMs: 100, text: '空');
    expect(sentence.words, isEmpty);
  });

  test('AsrSentence 深度相等：内容相同（含 words）的两个实例相等', () {
    const a = AsrSentence(
        startMs: 0, endMs: 100, text: '同', words: [word1]);
    const b = AsrSentence(
        startMs: 0, endMs: 100, text: '同', words: [word1]);
    expect(a == b, true);
    expect(a.hashCode, b.hashCode);
  });

  test('AsrSentence words 不同则不相等', () {
    const a = AsrSentence(startMs: 0, endMs: 100, text: '同', words: [word1]);
    const b = AsrSentence(startMs: 0, endMs: 100, text: '同', words: [word2]);
    expect(a == b, false);
  });
}

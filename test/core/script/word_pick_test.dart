import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/word_pick.dart';

/// 人在台词上**选中一段字**，要能换算成词序号区间。
///
/// 难点在于词和原文对不齐：ASR 给的词里常常没有标点（「如果」「你」
/// 「觉得」…），而界面上显示的是带标点的原文。此前字幕就栽在这里——
/// 空隙一律当标点还原，遇到「69.91」这种被并成一个词的数字直接崩掉，
/// 出现一字一屏。
void main() {
  const src = '如果你觉得有点贵，那就趁现在活动赶紧买';
  final words = [
    for (final t in ['如果', '你', '觉得', '有点', '贵', '那就', '趁现在', '活动', '赶紧', '买'])
      VoiceWord(text: t, startMs: 0, endMs: 100),
  ];

  group('选中的字符区间 → 词区间', () {
    test('正好选中前五个词', () {
      final r = wordRangeOf(src, words, 0, '如果你觉得有点贵'.length);
      expect(r, (start: 0, end: 5));
    });

    test('选中中间几个词', () {
      final start = src.indexOf('趁现在');
      final r = wordRangeOf(src, words, start, start + '趁现在活动'.length);
      expect(r, (start: 6, end: 8));
    });

    test('选到半个词也算上那个词——不能把一个词切两半', () {
      final r = wordRangeOf(src, words, 0, 3); // 「如果你」的一部分
      expect(r!.start, 0);
      expect(r.end, greaterThanOrEqualTo(2));
    });

    test('选区落在标点上：标点不属于任何词，跟着前一个词走', () {
      final comma = src.indexOf('，');
      final r = wordRangeOf(src, words, 0, comma + 1);
      expect(r, (start: 0, end: 5), reason: '逗号不该多算出一个词');
    });

    test('空选区返回 null——没选中就没有区间', () {
      expect(wordRangeOf(src, words, 3, 3), isNull);
    });

    test('没有逐字时间就没法划词', () {
      expect(wordRangeOf(src, const [], 0, 5), isNull);
    });
  });

  group('词区间 → 字符区间（界面要给已占用的字上底色）', () {
    test('前五个词对应到原文的位置', () {
      final r = charRangeOf(src, words, 0, 5);
      expect(src.substring(r!.start, r.end), '如果你觉得有点贵');
    });

    test('越界的区间夹回来', () {
      expect(charRangeOf(src, words, 0, 999), isNotNull);
    });
  });

  group('哪些字已经被占住了', () {
    test('把几镜的词区间摊平成字符区间，界面照着上底色', () {
      final taken = takenCharRanges(src, words, const [
        (start: 0, end: 5),
        (start: 8, end: 10),
      ]);
      expect(taken, hasLength(2));
      expect(src.substring(taken.first.start, taken.first.end), '如果你觉得有点贵');
    });

    test('选区碰到已占用的字就不能划——按钮不该出现', () {
      final taken = takenCharRanges(src, words, const [(start: 0, end: 5)]);
      expect(overlapsTaken(taken, 0, 4), isTrue);
      expect(overlapsTaken(taken, 2, 6), isTrue, reason: '部分重叠也算');
      final free = src.indexOf('那就');
      expect(overlapsTaken(taken, free, free + 2), isFalse);
    });
  });
}

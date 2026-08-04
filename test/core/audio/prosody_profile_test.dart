import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/audio/prosody_profile.dart';

/// 「再不买就恢复69.9一瓶了。」的真实字级时间戳（那条片子 U1）
const _words = [
  AsrWord(startMs: 80, endMs: 200, text: '再'),
  AsrWord(startMs: 200, endMs: 400, text: '不'),
  AsrWord(startMs: 400, endMs: 560, text: '买'),
  AsrWord(startMs: 680, endMs: 920, text: '就'),
  AsrWord(startMs: 920, endMs: 1120, text: '恢'),
  AsrWord(startMs: 1120, endMs: 1240, text: '复'),
  AsrWord(startMs: 1280, endMs: 2080, text: '69.9'),
  AsrWord(startMs: 2080, endMs: 2240, text: '一'),
  AsrWord(startMs: 2240, endMs: 2400, text: '瓶'),
  AsrWord(startMs: 2400, endMs: 2520, text: '了'),
];

void main() {
  group('从字级时间戳量出语速', () {
    test('字/秒按有效说话时长算，不含前后静音', () {
      final p = ProsodyProfile.measure(words: _words, referenceCharsPerSec: 4.1);

      expect(p.charsPerSec, closeTo(10 / 2.44, 0.1),
          reason: '10 个字，从 80ms 说到 2520ms');
    });

    test('相对全片均值给出快慢判断', () {
      final fast = ProsodyProfile.measure(words: _words, referenceCharsPerSec: 3.0);
      final slow = ProsodyProfile.measure(words: _words, referenceCharsPerSec: 6.0);

      expect(fast.pace, Pace.fast);
      expect(slow.pace, Pace.slow);
    });

    test('差得不多时算正常，不硬分快慢', () {
      final p = ProsodyProfile.measure(words: _words, referenceCharsPerSec: 4.1);

      expect(p.pace, Pace.normal);
    });
  });

  group('停顿', () {
    test('字与字之间超过阈值的空档算一次停顿', () {
      final p = ProsodyProfile.measure(words: _words, referenceCharsPerSec: 4.1);

      expect(p.pauseCount, 1,
          reason: '只有 560→680 这处 120ms 超过阈值；1240→1280 只有 40ms，'
              '那是连读时的自然衔接，算进去会让每句话都显得「停顿很多」');
      expect(p.longestPauseMs, 120);
    });

    test('没有停顿时如实为 0，不编一个出来', () {
      final p = ProsodyProfile.measure(
        words: const [
          AsrWord(startMs: 0, endMs: 200, text: '甲'),
          AsrWord(startMs: 200, endMs: 400, text: '乙'),
        ],
        referenceCharsPerSec: 4.1,
      );

      expect(p.pauseCount, 0);
      expect(p.longestPauseMs, 0);
    });
  });

  group('被拖长的字（重音的代理信号）', () {
    test('明显长于平均的字被挑出来', () {
      final p = ProsodyProfile.measure(words: _words, referenceCharsPerSec: 4.1);

      expect(p.stressedWords, contains('69.9'),
          reason: '「69.9」占了 800ms，是平均字长的三倍多——价格被刻意强调');
    });

    test('字长都差不多时不硬挑重音', () {
      final p = ProsodyProfile.measure(
        words: const [
          AsrWord(startMs: 0, endMs: 200, text: '甲'),
          AsrWord(startMs: 200, endMs: 400, text: '乙'),
          AsrWord(startMs: 400, endMs: 600, text: '丙'),
        ],
        referenceCharsPerSec: 4.1,
      );

      expect(p.stressedWords, isEmpty);
    });
  });

  group('退化情况', () {
    test('没有字级时间戳时返回一个「什么都不知道」的画像，不崩', () {
      final p = ProsodyProfile.measure(words: const [], referenceCharsPerSec: 4.1);

      expect(p.charsPerSec, 0);
      expect(p.pace, Pace.normal);
      expect(p.stressedWords, isEmpty);
      expect(p.hasSignal, isFalse,
          reason: '量不出东西时要说出来，别让上层把一个空画像当真');
    });

    test('时间戳倒错时不产生负数', () {
      final p = ProsodyProfile.measure(
        words: const [AsrWord(startMs: 500, endMs: 100, text: '坏')],
        referenceCharsPerSec: 4.1,
      );

      expect(p.charsPerSec, greaterThanOrEqualTo(0));
      expect(p.longestPauseMs, greaterThanOrEqualTo(0));
    });
  });
}

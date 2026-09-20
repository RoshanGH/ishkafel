import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/subtitle/heard_words.dart';
import 'package:ishkafel/core/subtitle/voice_source.dart';
import 'package:ishkafel/core/time/rational.dart';
import 'package:ishkafel/core/timeline/composed_frames.dart';

/// 「这一镜的画面里，人耳朵听到的是哪几个字？」
///
/// 这**不是**为了让字幕去对齐 ASR——产品负责人说得很清楚，时间对不上无所谓。
/// 它是 Agent 判断「这一镜该显示哪几个字」的唯一事实依据。
///
/// 听到什么 = 事实，软件给；显示什么 = 判断，Agent 定。两件事永不混写。
void main() {
  List<SemanticUnit> units() => const [
        SemanticUnit(
          uid: 'u0', index: 0, startMs: 0, endMs: 2000, transcript: '甲乙',
          shots: [
            Shot(startMs: 0, endMs: 1000),
            Shot(startMs: 1000, endMs: 2000),
          ],
        ),
      ];

  /// 「甲」在 0~500ms，「乙」横跨 900~1100ms —— 它骑在两镜的边界上
  const sentences = [
    AsrSentence(startMs: 0, endMs: 1100, text: '甲乙', words: [
      AsrWord(startMs: 0, endMs: 500, text: '甲', confidence: 0.99),
      AsrWord(startMs: 900, endMs: 1100, text: '乙', confidence: 0.42),
    ]),
  ];

  ComposedFrames framesOf({Map<int, int> whole = const {}}) =>
      ComposedFrames.of(
        timeline: ComposedTimeline.of(units: units(), wholeDurations: whole),
        fps: Rational.fps30,
      );

  Heard heardAt(int shotIndex,
          {VoiceSource source = VoiceSource.original,
          Map<int, int> whole = const {}}) =>
      heardInShot(
        frames: framesOf(whole: whole),
        units: units(),
        unitIndex: 0,
        shotIndex: shotIndex,
        source: source,
        originalSentences: sentences,
      );

  test('听到的字按成片帧轴落位', () {
    final h = heardAt(0);
    expect(h.text, contains('甲'));
    expect(h.words!.first.firstFrame, 0);
  });

  test('骑在边界上的字要点名它溢到了哪一镜', () {
    final spill = heardAt(0).words!.firstWhere((w) => w.text == '乙');
    expect(spill.spillsInto, 'U1S2',
        reason: '「第二句的最后一个字其实是下一个镜头的第一个字」——'
            '这个字段就是那句话的机械表达');
  });

  test('置信度带出来——低置信度是听错字的高发处', () {
    final low = heardAt(0).words!.firstWhere((w) => w.text == '乙');
    expect(low.confidence, 0.42);
  });

  test('整段替换：不给词级，也不编时间', () {
    final h = heardAt(0, source: VoiceSource.replaced, whole: {0: 5000});
    expect(h.words, isNull,
        reason: '时长跟着素材走，逐词位置只能按比例摊——那是假精度');
    expect(h.note, contains('已经不成立'));
  });

  test('手动加的单元：没有台词来源，如实说，不留空', () {
    final h = heardAt(0, source: VoiceSource.none);
    expect(h.words, isNull);
    expect(h.text, isEmpty);
    expect(h.note, isNotNull,
        reason: '空值和「听到的是空」要分得开');
  });
}

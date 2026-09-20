import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/frame_time.dart';
import 'package:ishkafel/core/subtitle/heard_words.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_problems.dart';

/// **只报机械可查的事实。**
///
/// 断句好不好看、读着顺不顺、错别字——一概不报。那些是判断，判断归 Agent。
/// 与同日定下的检索原则同源：软件只报事实。
void main() {
  const span = FrameSpan(first: 0, last: 29, fps: 30);

  Set<String> kindsOf({
    Heard heard = const Heard(text: '甲乙'),
    List<SubtitleLine> lines = const [],
    int slotDurationMs = 1000,
  }) =>
      subtitleProblemsOf(
        shotSpan: span,
        heard: heard,
        lines: lines,
        slotDurationMs: slotDurationMs,
      ).map((p) => p.kind).toSet();

  test('一个字跨了镜头边界', () {
    final kinds = kindsOf(
      heard: const Heard(text: '乙', words: [
        HeardWord(text: '乙', firstFrame: 25, lastFrame: 33, spillsInto: 'U1S2'),
      ]),
      lines: const [SubtitleLine(startMs: 0, endMs: 900, text: '乙')],
    );
    expect(kinds, contains('wordSplit'));
  });

  test('字幕越出这一镜', () {
    expect(
      kindsOf(lines: const [SubtitleLine(startMs: 0, endMs: 5000, text: '甲')]),
      contains('outOfSlot'),
    );
  });

  test('两段打架', () {
    expect(
      kindsOf(lines: const [
        SubtitleLine(startMs: 0, endMs: 600, text: '甲'),
        SubtitleLine(startMs: 500, endMs: 900, text: '乙'),
      ]),
      contains('overlap'),
    );
  });

  test('零长段 / 空文本段', () {
    expect(
      kindsOf(lines: const [SubtitleLine(startMs: 100, endMs: 100, text: '')]),
      contains('empty'),
    );
  });

  test('听得到话却没有字幕', () {
    expect(kindsOf(lines: const []), contains('heardButSilent'));
  });

  test('没有台词来源却挂着字幕', () {
    expect(
      kindsOf(
        heard: const Heard(text: '', note: '整段替换，台词时间已经不成立'),
        lines: const [SubtitleLine(startMs: 0, endMs: 900, text: '哪来的')],
      ),
      contains('silentButCaptioned'),
    );
  });

  test('一切正常时一条都不报——不许为了显得勤快而凑数', () {
    expect(
      kindsOf(lines: const [SubtitleLine(startMs: 0, endMs: 900, text: '甲乙')]),
      isEmpty,
    );
  });

  test('说不出落在哪一镜时，文案不许拼成「落在 片尾之后 上」', () {
    final problems = subtitleProblemsOf(
      shotSpan: span,
      heard: const Heard(text: '乙', words: [
        HeardWord(
            text: '乙', firstFrame: 25, lastFrame: 33, spillsInto: '片尾之后'),
      ]),
      lines: const [SubtitleLine(startMs: 0, endMs: 900, text: '乙')],
      slotDurationMs: 1000,
    );
    final note = problems.firstWhere((p) => p.kind == 'wordSplit').note;
    expect(note, contains('片尾之后'));
    expect(note, isNot(contains('落在 片尾之后 上')),
        reason: '上游特意不编造假标号，这里不能把那句实话硬塞进介词结构');
  });

  test('是镜头标号时照旧说「落在 X 上」', () {
    final problems = subtitleProblemsOf(
      shotSpan: span,
      heard: const Heard(text: '乙', words: [
        HeardWord(
            text: '乙', firstFrame: 25, lastFrame: 33, spillsInto: 'U1S2'),
      ]),
      lines: const [SubtitleLine(startMs: 0, endMs: 900, text: '乙')],
      slotDurationMs: 1000,
    );
    expect(problems.firstWhere((p) => p.kind == 'wordSplit').note,
        contains('落在 U1S2 上'));
  });
}

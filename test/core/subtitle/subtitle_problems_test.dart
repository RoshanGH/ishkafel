import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/frame_time.dart';
import 'package:ishkafel/core/subtitle/caption_box.dart';
import 'package:ishkafel/core/subtitle/heard_words.dart';
import 'package:ishkafel/core/subtitle/subtitle_overlay.dart';
import 'package:ishkafel/core/subtitle/subtitle_problems.dart';
import 'package:ishkafel/core/subtitle/subtitle_style.dart';

/// **只报机械可查的事实。**
///
/// 断句好不好看、读着顺不顺、错别字——一概不报。那些是判断，判断归 Agent。
/// 与同日定下的检索原则同源：软件只报事实。
void main() {
  const span = FrameSpan(first: 0, last: 29, fps: 30);

  // 默认给一个放得下、没有烧字的矩形——这两条不是本文件要测的东西，
  // 免得每条既有用例都要为它们额外操心
  final defaultCaption =
      captionBoxOf(style: const SubtitleStyle(), text: '');

  Set<String> kindsOf({
    Heard heard = const Heard(text: '甲乙'),
    List<SubtitleLine> lines = const [],
    int slotDurationMs = 1000,
    CaptionBox? caption,
    List<String> burnedText = const [],
  }) =>
      subtitleProblemsOf(
        shotSpan: span,
        heard: heard,
        lines: lines,
        slotDurationMs: slotDurationMs,
        caption: caption ?? defaultCaption,
        burnedText: burnedText,
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

  test('一行字这个字号一屏放不下，会被自动切开', () {
    final overflowingCaption = captionBoxOf(
      style: const SubtitleStyle(),
      text: '这一句话特别特别长长到一屏根本放不下它会被自动切成两屏',
    );
    expect(
      kindsOf(
        lines: const [
          SubtitleLine(
              startMs: 0,
              endMs: 900,
              text: '这一句话特别特别长长到一屏根本放不下它会被自动切成两屏')
        ],
        caption: overflowingCaption,
      ),
      contains('captionOverflows'),
    );
  });

  test('已经切成几屏、每屏都放得下，不许报超长', () {
    // 三行，每行都 <= maxCharsPerScreen（默认字号下是 15），但加起来
    // 远超——按总字数求和会误报，按逐行判就不会
    expect(
      kindsOf(lines: const [
        SubtitleLine(startMs: 0, endMs: 300, text: '一二三四五六七八九十'),
        SubtitleLine(startMs: 300, endMs: 600, text: '甲乙丙丁戊己庚辛壬癸'),
        SubtitleLine(startMs: 600, endMs: 900, text: '子丑寅卯辰巳午未申酉'),
      ]),
      isNot(contains('captionOverflows')),
    );
  });

  test('素材画面上自带烧录字，要点名两层字打架的风险', () {
    expect(
      kindsOf(
        lines: const [SubtitleLine(startMs: 0, endMs: 900, text: '甲乙')],
        burnedText: const ['冰冰凉凉的好舒服呀'],
      ),
      contains('burnedTextPresent'),
    );
  });

  test('素材画面干净就不报', () {
    expect(
      kindsOf(lines: const [SubtitleLine(startMs: 0, endMs: 900, text: '甲乙')]),
      isNot(contains('burnedTextPresent')),
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
      caption: defaultCaption,
      burnedText: const [],
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
      caption: defaultCaption,
      burnedText: const [],
    );
    expect(problems.firstWhere((p) => p.kind == 'wordSplit').note,
        contains('落在 U1S2 上'));
  });
}

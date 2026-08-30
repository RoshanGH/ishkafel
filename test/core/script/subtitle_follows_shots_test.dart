import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/shot_allocation.dart';

/// 划词建镜之后，**字幕默认跟着画面切**。
///
/// 这是划词的另一半价值：一次操作同时定下画面边界和字幕边界，
/// 不会再出现「字幕停在 8 个字上，配音还在念后面 18 个字」那种脱节
/// （真机数据里就有这么一行）。
///
/// 复用现有的「subtitleScreens == null = 自动」语义：人一动手改字幕，
/// 那一行就脱钩，之后镜头怎么变都不再重切。
void main() {
  /// 12 个字，每字 500ms
  final words = [
    for (var i = 0; i < 12; i++)
      VoiceWord(text: '字$i', startMs: i * 500, endMs: (i + 1) * 500),
  ];
  final vo = LineVoiceover(
    audioPath: '/v.mp3',
    durationMs: 6000,
    sourceText: '字0字1字2字3字4字5字6字7字8字9字10字11',
    voiceId: 'v',
    speechRate: 0,
    words: words,
  );

  LineShot bound(int s, int e) => LineShot(
      materialId: s + 1, name: 'm$s', durationMs: 9999,
      allocMs: (e - s) * 500, startWord: s, endWord: e);
  const free = LineShot(
      materialId: 99, name: '自由', durationMs: 9999, allocMs: 1500);

  ScriptLine lineWith(List<LineShot> shots) =>
      ScriptLine.create(text: vo.sourceText)
          .withVoiceover(vo)
          .withShots(shots);

  test('划词镜的边界成为字幕切点', () {
    final line = lineWith([bound(0, 4), free, bound(9, 12)]);
    final screens = line.subtitleScreensAt(maxChars: 99);
    // 切点：0（划词）、4（划词结束）、9（下一个划词开始）、12
    expect(screens, hasLength(3));
    expect(screens[0].text, '字0字1字2字3');
    expect(screens[2].text, '字9字10字11');
  });

  test('中间的自由段自成一屏——不按里面几个镜头再切碎', () {
    final line = lineWith([bound(0, 4), free, free, free, bound(9, 12)]);
    final screens = line.subtitleScreensAt(maxChars: 99);
    expect(screens, hasLength(3), reason: '中间 3 个自由镜仍然只出一屏字幕');
  });

  test('字幕屏一屏太多字时照样再细分——可读性是硬要求', () {
    final line = lineWith([bound(0, 12)]);
    final screens = line.subtitleScreensAt(maxChars: 4);
    expect(screens.length, greaterThan(1));
    // 但细分不能跨出划词镜的边界
    expect(screens.first.text.length, lessThanOrEqualTo(4 * 3));
  });

  test('一个划词镜都没有：还是原来那套自动分屏', () {
    final line = lineWith([free, free]);
    final screens = line.subtitleScreensAt(maxChars: 99);
    expect(screens, hasLength(1), reason: '没有划词就没有画面边界可依');
  });

  test('人手动改过字幕的行不受影响——脱钩了就别再自动重切', () {
    final line = lineWith([bound(0, 4), bound(4, 12)]).withSubtitleScreens(
        const [SubtitleScreen(startWord: 0, text: '我自己写的')]);
    final screens = line.subtitleScreensAt(maxChars: 99);
    expect(screens, hasLength(1));
    expect(screens.first.text, '我自己写的');
  });

  test('划词镜没铺满整句：字幕跟着画面长度走，缺口由分配不足去报', () {
    // 这一行只有 2 秒画面（4 个字），后面 4 秒没有镜头。
    // 字幕不该凭空出现在没有画面的地方——那段是「铺不满」，
    // 由 shortfallMs 拦住整行进预览，而不是让字幕假装完整
    final line = lineWith([bound(0, 4)]);
    final screens = line.subtitleScreensAt(maxChars: 99);
    expect(screens, hasLength(1));
    expect(screens.first.text, '字0字1字2字3');
    expect(ShotAllocation.shortfallMs(line.shots, 6000), 4000,
        reason: '缺的那 4 秒要如实报出来，不能靠字幕把它盖过去');
  });
}

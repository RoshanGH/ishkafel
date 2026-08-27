import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/subtitle_mismatch.dart';

/// 手写的字幕**明显盖不住这一屏的语音**时要点名。
///
/// 真机数据里就有这么一行：第 1 屏覆盖 26 个字、4.7 秒，人手写的字幕只有
/// 8 个字。那 4.7 秒里配音一直在念「…那就趁现在活动赶紧买，不用10瓶8瓶
/// 的买」，字幕却停在「如果你觉得有点贵」上不动，一路漏到成片。
///
/// 触发它的是一次正常操作（改字幕），但**软件一声不吭就收下了**——
/// 能被正常操作轻易做出来、做出来还没人吭声的坏状态，是程序的责任。
void main() {
  final words = [
    for (var i = 0; i < 26; i++)
      VoiceWord(text: '字', startMs: i * 180, endMs: (i + 1) * 180),
  ];
  final vo = LineVoiceover(
    audioPath: '/v.mp3',
    durationMs: 4700,
    sourceText: '字' * 26,
    voiceId: 'v',
    speechRate: 0,
    words: words,
  );
  ScriptLine lineWith(List<SubtitleScreen> screens) =>
      ScriptLine.create(text: vo.sourceText)
          .withVoiceover(vo)
          .withSubtitleScreens(screens);

  test('手写字幕只盖住一小半：点名', () {
    final line = lineWith(const [SubtitleScreen(startWord: 0, text: '八个字啊八个字')]);
    final issues = subtitleMismatches(line);
    expect(issues, hasLength(1));
    expect(issues.single.message, contains('26'));
    expect(issues.single.message, contains('4.7'));
  });

  test('字数差不多就不啰嗦——同音改写、去掉语气词是正常操作', () {
    final line = lineWith([
      SubtitleScreen(startWord: 0, text: '字' * 24),
    ]);
    expect(subtitleMismatches(line), isEmpty);
  });

  test('故意留空的那一屏不算——""就是「这屏不出字」', () {
    final line = lineWith(const [SubtitleScreen(startWord: 0, text: '')]);
    expect(subtitleMismatches(line), isEmpty);
  });

  test('没手写过的行不管——自动分屏本来就对得上', () {
    final line = ScriptLine.create(text: vo.sourceText).withVoiceover(vo);
    expect(subtitleMismatches(line), isEmpty);
  });

  test('画面行没有配音，无从比对', () {
    expect(subtitleMismatches(ScriptLine.create(text: '')), isEmpty);
  });

  test('多屏各算各的，一次全报出来', () {
    final line = lineWith(const [
      SubtitleScreen(startWord: 0, text: '短'),
      SubtitleScreen(startWord: 13, text: '也短'),
    ]);
    expect(subtitleMismatches(line), hasLength(2));
  });
}

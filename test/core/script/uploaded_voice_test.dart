import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/uploaded_voice.dart';

/// 人自己录的配音。
///
/// 为什么要有这条路：合成语音的情绪天花板就在那儿（预置音色、逐句之间没有
/// 上下文），原片那个人激动地在争吵，合成出来还是平的。与其继续磨，不如让
/// 人自己念——念成什么样就是什么样，**确定性**。
///
/// 而且时间根从「合成出来多长」变成「人真的念了多长」，画面对齐反而更实在。
void main() {
  ScriptDoc docWith(String text) => ScriptDoc([ScriptLine.create(text: text)])
      .withDefaultVoiceId('vivi');

  final words = [
    const VoiceWord(text: '早', startMs: 0, endMs: 200),
    const VoiceWord(text: '就', startMs: 200, endMs: 420),
  ];

  test('装进去之后，时长和逐字时间都以这段音频为准', () {
    final next = applyUploadedVoice(
      doc: docWith('早就跟你们说了'),
      lineIndex: 0,
      audioPath: '/我录的.wav',
      durationMs: 2600,
      words: words,
      heardText: '早就跟你们说了',
    );
    final vo = next.lines.first.voiceover!;
    expect(vo.audioPath, '/我录的.wav');
    expect(vo.durationMs, 2600, reason: '这一行有多长，从此由这段录音说了算');
    expect(vo.words.length, 2, reason: '断句和字幕打轴都要靠逐字时间');
  });

  test('音频里说的和脚本不一样：以音频为准', () {
    final next = applyUploadedVoice(
      doc: docWith('早就跟你们说了'),
      lineIndex: 0,
      audioPath: '/我录的.wav',
      durationMs: 2600,
      words: words,
      heardText: '早就跟你们讲过了嘛',
    );
    expect(next.lines.first.text, '早就跟你们讲过了嘛',
        reason: '人已经念出来了，那就是事实——改脚本去将就音频，'
            '而不是反过来要求人重录');
    expect(next.lines.first.voiceover!.sourceText, '早就跟你们讲过了嘛',
        reason: '两边对不上的话，下一秒就被判成「台词改了、配音过期」');
  });

  test('**绝不能被 TTS 重配盖掉**——这是这条路的命门', () {
    final next = applyUploadedVoice(
      doc: docWith('早就跟你们说了'),
      lineIndex: 0,
      audioPath: '/我录的.wav',
      durationMs: 2600,
      words: words,
      heardText: '早就跟你们说了',
    );
    expect(next.voiceStateOf(next.lines.first), LineVoiceState.fresh,
        reason: '人工配音要是被判成过期，下一次 script voice 就直接拿合成的'
            '把人辛苦录的盖掉了');
    expect(isHumanVoice(next.lines.first), isTrue);
  });

  test('换了全片基调，也不该动人自己录的那几句', () {
    var next = applyUploadedVoice(
      doc: docWith('早就跟你们说了'),
      lineIndex: 0,
      audioPath: '/我录的.wav',
      durationMs: 2600,
      words: words,
      heardText: '早就跟你们说了',
    );
    next = next.withDefaultVoiceId('小天');
    expect(next.voiceStateOf(next.lines.first), LineVoiceState.fresh,
        reason: '人换全片音色，意思是「合成的那些换掉」，'
            '不是「把我自己录的也重做一遍」');
  });

  test('人工配音和合成的可以混着用', () {
    var doc = ScriptDoc([
      ScriptLine.create(text: '第一句'),
      ScriptLine.create(text: '第二句'),
    ]).withDefaultVoiceId('vivi');
    doc = applyUploadedVoice(
      doc: doc,
      lineIndex: 1,
      audioPath: '/第二句我自己录的.wav',
      durationMs: 1800,
      words: words,
      heardText: '第二句',
    );
    expect(isHumanVoice(doc.lines[0]), isFalse);
    expect(isHumanVoice(doc.lines[1]), isTrue,
        reason: '只重录不满意的那几句，其余留着——这才是实际用法');
  });

  test('一个字都没听出来：保留原台词，别把台词洗成空的', () {
    final next = applyUploadedVoice(
      doc: docWith('早就跟你们说了'),
      lineIndex: 0,
      audioPath: '/我录的.wav',
      durationMs: 2600,
      words: const [],
      heardText: '   ',
    );
    expect(next.lines.first.text, '早就跟你们说了');
  });
}

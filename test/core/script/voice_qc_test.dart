import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/script/voice_qc.dart';

/// 把一串字做成词表（等距），模拟 ASR 转写合成音频的结果
List<VoiceWord> heard(String text, {int durationMs = 6000}) => [
      for (var i = 0; i < text.length; i++)
        VoiceWord(
            text: text[i],
            startMs: (i * durationMs / text.length).round(),
            endMs: (i * durationMs / text.length).round() + 120),
    ];

void main() {
  const src = '现在我们家每个月都有定期清理冰箱的好习惯，不然里面的食物只会越放越脏。';

  test('念的和写的对得上：放行', () {
    expect(
        voiceDefect(
            source: src,
            heard: heard('现在我们家每个月都有定期清理冰箱的好习惯不然里面的食物只会越放越脏'),
            durationMs: 6048),
        isNull);
  });

  test('尾部卡住反复念同一句：判为坏，不许进成片', () {
    // 大模型 TTS 的老毛病——解码陷进循环，后半句两个词一直重复
    final defect = voiceDefect(
      source: src,
      heard: heard(
          '现在我们家每个月都有定期清理冰箱的好习惯不然里面的食物只会越放越脏'
          '越放越脏越放越脏越放越脏越放越脏',
          durationMs: 12000),
      durationMs: 12000,
    );
    expect(defect, isNotNull);
    expect(defect, contains('重复'));
  });

  test('念到一半断了：也判坏', () {
    final defect = voiceDefect(
        source: src, heard: heard('现在我们家每个月都有'), durationMs: 2000);
    expect(defect, isNotNull);
    expect(defect, contains('没念完'));
  });

  test('同音字、数字写法不同：不许误杀', () {
    // ASR 把「10瓶8瓶」听成「十瓶八瓶」、「厨垫」听成「橱垫」是常事
    expect(
        voiceDefect(
            source: '不用10瓶8瓶的买，厨房厨垫上的油渍',
            heard: heard('不用十瓶八瓶的买橱房橱垫上的油渍'),
            durationMs: 4000),
        isNull);
  });

  test('没有转写结果就不下结论——没证据不许判人死刑', () {
    expect(
        voiceDefect(source: src, heard: const [], durationMs: 6000), isNull);
  });

  test('叠词本身不算重复（「看看啊，看看啊」是台词写的）', () {
    expect(
        voiceDefect(
            source: '看看啊，看看啊',
            heard: heard('看看啊看看啊', durationMs: 1900),
            durationMs: 1900),
        isNull);
  });

  test('语速快得不像人话：判坏（塞了太多字）', () {
    final defect = voiceDefect(
        source: src,
        heard: heard('现在我们家每个月都有定期清理冰箱的好习惯不然里面的食物只会越放越脏',
            durationMs: 2000),
        durationMs: 2000);
    expect(defect, isNotNull);
  });
}

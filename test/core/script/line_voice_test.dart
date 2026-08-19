import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/script/line_voice_service.dart';
import 'package:ishkafel/core/script/script_doc.dart';

/// 「生成配音」：一行台词 → TTS → 落盘 → 量时长；状态由快照对比派生。
class _FakeTts extends TtsClient {
  final TtsResult? result;
  final calls = <(String, String, int?)>[];

  _FakeTts({this.result}) : super(appId: 'test', accessToken: 'test');

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String speaker,
    String? instruction,
    int? speechRate,
    String resourceId = TtsClient.presetResource,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    calls.add((text, speaker, speechRate));
    return result!;
  }
}

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('line_voice'));
  tearDown(() => dir.delete(recursive: true));

  LineVoiceService build(_FakeTts tts, {int measured = 3200}) =>
      LineVoiceService(
          tts: tts, outputDir: dir, measureMs: (_) async => measured);

  test('生成：音频落盘、时长按实际量、快照记录生成参数、字级时间戳带回', () async {
    final tts = _FakeTts(
        result: TtsResult(audio: Uint8List.fromList([1, 2, 3]), words: const [
      TtsWord(word: '你', startMs: 0, endMs: 200),
      TtsWord(word: '好', startMs: 200, endMs: 420),
    ]));
    final vo = await build(tts).generate(
        lineId: 'l1', text: ' 你好 ', voiceId: 'v-1', speechRate: 25);

    expect(File(vo.audioPath).readAsBytesSync(), [1, 2, 3]);
    expect(vo.durationMs, 3200, reason: '时长按 ffprobe 实际量，不信尾字时间戳');
    expect(vo.sourceText, '你好', reason: '快照存 trim 后的文案');
    expect(vo.voiceId, 'v-1');
    expect(vo.speechRate, 25);
    expect(vo.words.map((w) => w.text), ['你', '好']);
    expect(tts.calls.single.$3, 25);
  });

  test('语速 0 不传给 TTS（火山原速就是不带参数）', () async {
    final tts = _FakeTts(result: TtsResult(audio: Uint8List.fromList([1])));
    await build(tts).generate(lineId: 'l1', text: '词', voiceId: 'v');
    expect(tts.calls.single.$3, isNull);
  });

  test('空台词直接拒绝，不白花一次合成', () async {
    final tts = _FakeTts(result: TtsResult(audio: Uint8List.fromList([1])));
    expect(
        () => build(tts).generate(lineId: 'l1', text: '  ', voiceId: 'v'),
        throwsA(isA<TtsException>()));
    expect(tts.calls, isEmpty);
  });

  test('量出 0 时长当失败并删掉空文件——0 时长的根会把整行时间轴归零', () async {
    final tts = _FakeTts(result: TtsResult(audio: Uint8List.fromList([1])));
    await expectLater(
        () => build(tts, measured: 0)
            .generate(lineId: 'l1', text: '词', voiceId: 'v'),
        throwsA(isA<TtsException>()));
    expect(dir.listSync().whereType<File>(), isEmpty, reason: '空音频不留孤儿');
  });

  group('配音状态派生（ScriptLine.voiceState）', () {
    LineVoiceover vo({String text = '你好', String voice = 'v', int rate = 0}) =>
        LineVoiceover(
            audioPath: '/a.mp3',
            durationMs: 1000,
            sourceText: text,
            voiceId: voice,
            speechRate: rate);

    test('没生成过 = none；参数一致 = fresh', () {
      final line = ScriptLine.create(text: '你好').withVoiceId('v');
      expect(line.voiceState, LineVoiceState.none);
      expect(line.withVoiceover(vo()).voiceState, LineVoiceState.fresh);
    });

    test('改台词 / 换音色 / 调语速 → stale（旧配音仍在，可听）', () {
      final line =
          ScriptLine.create(text: '你好').withVoiceId('v').withVoiceover(vo());
      expect(line.withText('你好呀').voiceState, LineVoiceState.stale);
      expect(line.withVoiceId('v2').voiceState, LineVoiceState.stale);
      expect(line.withSpeechRate(25).voiceState, LineVoiceState.stale);
      expect(line.withText('你好呀').voiceover, isNotNull,
          reason: '过期只是提醒，不是没收');
    });

    test('配音产物随 json 往返一字不差（含字级时间戳）', () {
      final line = ScriptLine.create(text: '你好')
          .withVoiceId('v')
          .withSpeechRate(25)
          .withVoiceover(LineVoiceover(
            audioPath: '/a.mp3',
            durationMs: 980,
            sourceText: '你好',
            voiceId: 'v',
            speechRate: 25,
            words: const [VoiceWord(text: '你', startMs: 0, endMs: 200)],
          ));
      final back = ScriptLine.tryFromJson(line.toJson())!;
      expect(back.toJson(), line.toJson());
      expect(back.voiceState, LineVoiceState.fresh);
      expect(back.voiceover!.words.single.endMs, 200);
    });
  });

  test('setVoiceoverById 按行 id 挂（生成期间行可能被移动，下标不可靠）', () {
    var doc = ScriptDoc.empty().updateText(0, 'A');
    doc = doc.insertAfter(0, text: 'B');
    final idB = doc.lines[1].id;
    doc = doc.move(1, 0); // B 挪到最前
    doc = doc.setVoiceoverById(
        idB,
        LineVoiceover(
            audioPath: '/b.mp3',
            durationMs: 500,
            sourceText: 'B',
            voiceId: 'v',
            speechRate: 0));
    expect(doc.lines[0].voiceover?.audioPath, '/b.mp3');
    expect(doc.lines[1].voiceover, isNull);
  });
}

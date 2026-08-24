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

  test('念岔了（结尾反复念同一句）自动重来一次；第二次好了就用第二次',
      () async {
    const text = '不然里面的食物只会越放越脏';
    var round = 0;
    final tts = _FakeTts(result: TtsResult(audio: Uint8List.fromList([1])));
    final service = LineVoiceService(
      tts: tts,
      outputDir: dir,
      measureMs: (_) async => 4000,
      transcribeWords: (_) async {
        round++;
        // 第一次抽风：后半句卡住反复念；第二次正常
        final heard = round == 1
            ? '不然里面的食物只会越放越脏越放越脏越放越脏越放越脏'
            : text;
        return [
          for (var i = 0; i < heard.length; i++)
            VoiceWord(
                text: heard[i],
                startMs: (i * 4000 / heard.length).round(),
                endMs: (i * 4000 / heard.length).round() + 100),
        ];
      },
    );
    final vo = await service.generate(lineId: 'l1', text: text, voiceId: 'v');

    expect(round, 2, reason: '第一次念岔了要自己重来，不能把卡住的声音交出去');
    expect(vo.words.map((w) => w.text).join(), text);
    expect(tts.calls, hasLength(2));
    expect(dir.listSync().whereType<File>(), hasLength(1),
        reason: '念岔的那份要删掉，不留孤儿文件');
  });

  test('重来一次还是念岔：点名报错，绝不把卡住的声音放进成片', () async {
    const text = '不然里面的食物只会越放越脏';
    final tts = _FakeTts(result: TtsResult(audio: Uint8List.fromList([1])));
    final service = LineVoiceService(
      tts: tts,
      outputDir: dir,
      measureMs: (_) async => 4000,
      transcribeWords: (_) async {
        const heard = '不然里面的食物只会越放越脏越放越脏越放越脏越放越脏';
        return [
          for (var i = 0; i < heard.length; i++)
            VoiceWord(
                text: heard[i],
                startMs: (i * 4000 / heard.length).round(),
                endMs: (i * 4000 / heard.length).round() + 100),
        ];
      },
    );
    await expectLater(
        service.generate(lineId: 'l1', text: text, voiceId: 'v'),
        throwsA(isA<TtsException>().having((e) => e.message, 'message',
            allOf(contains('重复'), contains('重试')))));
    expect(dir.listSync().whereType<File>(), isEmpty,
        reason: '两份坏音频都不留');
  });

  test('TTS 不给词级时间戳时用 ASR 转写补上（字幕按镜头切分的地基）',
      () async {
    final tts = _FakeTts(result: TtsResult(audio: Uint8List.fromList([1])));
    File? transcribed;
    final service = LineVoiceService(
      tts: tts,
      outputDir: dir,
      measureMs: (_) async => 2000,
      transcribeWords: (audio) async {
        transcribed = audio;
        return const [
          VoiceWord(text: '家人们', startMs: 0, endMs: 600),
          VoiceWord(text: '看', startMs: 700, endMs: 900),
        ];
      },
    );
    final vo = await service.generate(
        lineId: 'l1', text: '家人们看', voiceId: 'v');
    expect(transcribed, isNotNull, reason: '合成完把 mp3 交给 ASR 转写');
    expect(vo.words.map((w) => w.text), ['家人们', '看']);
  });

  test('ASR 转写失败不挡配音——words 留空，字幕退回整句', () async {
    final tts = _FakeTts(result: TtsResult(audio: Uint8List.fromList([1])));
    final service = LineVoiceService(
      tts: tts,
      outputDir: dir,
      measureMs: (_) async => 2000,
      transcribeWords: (_) async => throw Exception('网络断了'),
    );
    final vo =
        await service.generate(lineId: 'l1', text: '词', voiceId: 'v');
    expect(vo.words, isEmpty);
    expect(vo.durationMs, 2000, reason: '配音本体不受转写失败影响');
  });

  test('TTS 自带词级时间戳时不再多花一次 ASR', () async {
    final tts = _FakeTts(
        result: TtsResult(audio: Uint8List.fromList([1]), words: const [
      TtsWord(word: '词', startMs: 0, endMs: 300),
    ]));
    var asrCalls = 0;
    final service = LineVoiceService(
      tts: tts,
      outputDir: dir,
      measureMs: (_) async => 2000,
      transcribeWords: (_) async {
        asrCalls++;
        return const [];
      },
    );
    await service.generate(lineId: 'l1', text: '词', voiceId: 'v');
    expect(asrCalls, 0);
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

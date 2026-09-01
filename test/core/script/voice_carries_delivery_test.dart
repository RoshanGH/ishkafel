import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/script/line_voice_service.dart';

/// **配音要带上「这句该怎么念」。**
///
/// 用户反馈：原片那个人是很激动地在争吵，克隆过来情绪变得非常扁平。
///
/// 查下来是三件事叠在一起，这条测试管其中最要紧的一件：
/// `TtsClient.synthesize` 有个 `instruction` 参数（火山的 `context_texts`，
/// 用一句自然语言说该怎么念，例如「用非常着急、语速很快的语气催促」），
/// 而**脚本成片这条线一处都没传**——每句都是默认语气念出来的，扁平是必然。
///
/// 讽刺的是能力早就有：`delivery_analyzer` 会从原片音频分析出这句的
/// 念法，替换裂变的「换音色」一直在用它。脚本成片手里同样握着参考片，
/// 只是没接上。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('voice'));
  tearDown(() => dir.deleteSync(recursive: true));

  ({LineVoiceService svc, List<String?> instructions}) make() {
    final seen = <String?>[];
    final svc = LineVoiceService(
      tts: _FakeTts(seen),
      outputDir: dir,
      measureMs: (f) async => 1200,
      transcribeWords: (f) async => const [],
    );
    return (svc: svc, instructions: seen);
  }

  test('给了念法，就要传到合成那一下', () async {
    final m = make();
    await m.svc.generate(
      lineId: 'l1',
      text: '早就跟你们说了',
      voiceId: 'vivi',
      instruction: '用非常激动、带着争辩的语气说这句话',
    );
    expect(m.instructions.single, '用非常激动、带着争辩的语气说这句话',
        reason: '不传的话，模型只会用默认语气平铺直叙——'
            '原片再激动也传不过来');
  });

  test('没有念法就不传，别塞个空串进去', () async {
    final m = make();
    await m.svc.generate(lineId: 'l1', text: '早就跟你们说了', voiceId: 'vivi');
    expect(m.instructions.single, isNull);
  });

  test('念法是空白的，当没有', () async {
    final m = make();
    await m.svc.generate(
        lineId: 'l1', text: '一句话', voiceId: 'vivi', instruction: '   ');
    expect(m.instructions.single, isNull,
        reason: '分析没出结果时给的是空串，别把空串当指令发出去');
  });
}

class _FakeTts implements TtsClient {
  final List<String?> seen;
  _FakeTts(this.seen);

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String speaker,
    String? instruction,
    int? speechRate,
    String resourceId = TtsClient.presetResource,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    seen.add(instruction);
    return TtsResult(audio: Uint8List(64), words: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

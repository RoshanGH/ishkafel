import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/script_run_command.dart';
import 'package:ishkafel/core/audio/delivery_analyzer.dart';
import 'package:ishkafel/core/audio/prosody_profile.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/line_delivery_service.dart';
import 'package:ishkafel/core/script/line_voice_service.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// **`script voice` 到底有没有把「这句该怎么念」送进合成。**
///
/// 中间隔着一层胶水：分析 → 指令 → generate(instruction:)。胶水断了，
/// 前面两层的测试全绿、成片照样是平的——所以这一层要单独钉住。
void main() {
  late Directory dir;
  late Directory voices;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voicecmd');
    voices = Directory('${dir.path}/voices')..createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  RenewTask taskWith(ScriptDoc doc) => RenewTask(
        id: 'sc1',
        seq: 1,
        name: '片子',
        sourcePath: null,
        script: doc,
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
      );

  ScriptDoc docWithRef({String? refVideo = '/ref/a.mp4'}) => ScriptDoc(
        [
          ScriptLine(
            id: 'l1',
            text: '早就跟你们说了',
            reference: refVideo == null
                ? null
                : LineRef(startMs: 1000, endMs: 3000, words: const [
                    VoiceWord(text: '早', startMs: 1000, endMs: 1200),
                    VoiceWord(text: '就', startMs: 1200, endMs: 1400),
                  ]),
          ),
        ],
        refVideoPath: refVideo,
      ).withDefaultVoiceId('zh_female_vv_uranus_bigtts');


  Future<(int code, List<String?> instructions, String log)> run(
    ScriptDoc doc, {
    DeliveryAnalyzer? analyzer,
  }) async {
    await FileTaskRepository(dir).save(taskWith(doc));
    final seen = <String?>[];
    final log = StringBuffer();
    final code = await runScriptVoiceCommand(
      rest: const ['sc1'],
      dataDir: dir,
      out: StringBuffer(),
      err: log,
      voiceFactory: (task) => LineVoiceService(
        tts: _FakeTts(seen),
        outputDir: voices,
        measureMs: (f) async => 1500,
      ),
      deliveryFactory: (task) => LineDeliveryService(
        analyzer: analyzer ?? _FakeAnalyzer(),
        slice: (_, _, _) async => const [1, 2, 3],
        cacheDir: dir,
      ),
    );
    return (code, seen, log.toString());
  }

  test('有参考片：听出来的念法要跟着这一句进合成', () async {
    final r = await run(docWithRef());
    expect(r.$1, 0);
    expect(r.$2.single, '用非常激动、带着争辩的语气说这句话',
        reason: '不传的话，原片那个人再激动也传不过来——用户反馈的就是这个');
  });

  test('手写脚本没有参考片：照旧不带指令，也不说什么降级', () async {
    final r = await run(docWithRef(refVideo: null));
    expect(r.$1, 0);
    expect(r.$2.single, isNull);
    expect(r.$3, isNot(contains('默认语气')));
  });

  test('分析挂了：音还是配得出来，但要在输出里说清哪一句退回了默认语气',
      () async {
    final r = await run(docWithRef(), analyzer: _BrokenAnalyzer());
    expect(r.$1, 0, reason: '听不了不该挡住配音');
    expect(r.$2.single, isNull);
    expect(r.$3, contains('默认语气'));
    expect(r.$3, contains('第 1 句'));
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

class _FakeAnalyzer implements DeliveryAnalyzer {
  @override
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  }) async =>
      const DeliveryAnalysis(
        description: '语速快、音量大，情绪激动',
        instruction: '用非常激动、带着争辩的语气说这句话',
      );
}

class _BrokenAnalyzer implements DeliveryAnalyzer {
  @override
  Future<DeliveryAnalysis> analyze({
    required List<int> audioWav,
    required String transcript,
    ProsodyProfile? prosody,
  }) async =>
      throw Exception('模型听不了这段音频');
}

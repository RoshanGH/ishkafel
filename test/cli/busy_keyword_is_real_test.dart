import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/busy_guard.dart';
import 'package:ishkafel/cli/commands/script_command.dart';
import 'package:ishkafel/cli/commands/script_run_command.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/tag_dimension.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/line_voice_service.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// **「别把同一件贵活儿跑两遍」那道劝告的判据，必须真的对得上。**
///
/// 判据是「在场状态的 `action` 里有没有那几个字」，而那句 `action` 是各命令
/// 自己拼的——**两边一个是代码一个是文案，最容易悄悄走散**。
/// 评审原话：把开工那句改成「这一轮 20 句要念」，判据当场失效，
/// 而所有测试照样全绿。
///
/// 所以这里**跑真命令、读真在场状态**，断言它带着 `busy_guard` 那份常量。
/// 文案和常量一旦走散，这几条会红。
void main() {
  late Directory dir;
  late Directory voices;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('busykw');
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
        createdAt: DateTime.utc(2026, 9, 18),
        updatedAt: DateTime.utc(2026, 9, 18),
      );

  test('script voice 开工那一刻，在场状态里带着「配音」这个判据词', () async {
    await FileTaskRepository(dir).save(taskWith(ScriptDoc([
      ScriptLine(id: 'l1', text: '第一句'),
    ]).withDefaultVoiceId('zh_female_vv_uranus_bigtts')));

    String? seen;
    await runScriptVoiceCommand(
      rest: const ['sc1'],
      dataDir: dir,
      out: StringBuffer(),
      err: StringBuffer(),
      voiceFactory: (task) => LineVoiceService(
        // 合成的那一刻去读在场状态：那时候开工已经报过了
        tts: _PeekingTts(() =>
            seen = readAgentPresence(dataDir: dir, taskId: 'sc1')?.action),
        outputDir: voices,
        measureMs: (f) async => 1500,
      ),
    );

    expect(seen, isNotNull,
        reason: '开工就该写在场状态——另一个进程要靠它才知道有人在做');
    expect(seen, contains(voiceBusyKeyword),
        reason: '判据认的就是这几个字。文案改了而常量没跟着改，'
            '「别重复花钱」那道劝告会静默失效');
  });

  test('script tag-ref 开工那一刻，在场状态里带着「打标」这个判据词', () async {
    final video = File('${dir.path}/ref.mp4')..writeAsStringSync('假视频');
    await FileTaskRepository(dir).save(taskWith(ScriptDoc([
      ScriptLine(
        id: 'l1',
        text: '一句台词',
        reference: LineRef(startMs: 0, endMs: 2000, cuts: const [1000]),
      ),
    ], refVideoPath: video.path)));

    String? seen;
    await runScriptTagRefCommand(
      rest: const ['sc1'],
      dataDir: dir,
      line: 1,
      tagger: _PeekingTagger(() =>
          seen = readAgentPresence(dataDir: dir, taskId: 'sc1')?.action),
      run: (exe, args) async {
        File(args.last)
          ..createSync(recursive: true)
          ..writeAsBytesSync([0xFF, 0xD8, 0xFF]);
        return ProcessResult(0, 0, '', '');
      },
      out: StringBuffer(),
      err: StringBuffer(),
    );

    expect(seen, isNotNull);
    expect(seen, contains(tagBusyKeyword),
        reason: '同上：判据和文案必须引用同一份常量');
  });
}

class _PeekingTts implements TtsClient {
  final void Function() peek;
  _PeekingTts(this.peek);

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String speaker,
    String? instruction,
    int? speechRate,
    String resourceId = TtsClient.presetResource,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    peek();
    return TtsResult(audio: Uint8List(64), words: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PeekingTagger extends ShotTagger {
  final void Function() peek;
  _PeekingTagger(this.peek) : super(chat: ArkChatClient(apiKey: '不会被用到'));

  @override
  Future<ShotUnderstanding> understand({
    required List<List<int>> frames,
    required List<TagDimension> dimensions,
    String? constraint,
  }) async {
    peek();
    return const ShotUnderstanding(description: '刚打出来的描述');
  }
}

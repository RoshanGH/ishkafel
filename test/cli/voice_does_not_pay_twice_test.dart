import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/commands/script_run_command.dart';
import 'package:ishkafel/core/audio/tts_client.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/script/line_voice_service.dart';
import 'package:ishkafel/core/script/script_doc.dart';
import 'package:ishkafel/core/storage/agent_presence.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// **同一句不许念两遍。**
///
/// TTS 按字符计费。「调用方命令超时了、以为失败又起一个」在真机上是常态
/// （25 句要跑好几分钟），此前替这件事挡枪的是任务锁：第二个进程撞锁干等，
/// 等完发现「没有需要配音的行」。锁删掉之后，幂等必须落到**每一句**上——
/// 每一句开工前重读一次盘，已经有配音的跳过。
///
/// 这条测试模拟的正是那个场面：第 1 句还在合成的时候，另一个进程把第 2、
/// 第 3 句配完了。**只信循环外那份 targets 的话，第 2、3 句会被再念一遍。**
void main() {
  late Directory dir;
  late Directory voices;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('voicetwice');
    voices = Directory('${dir.path}/voices')..createSync(recursive: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const voiceId = 'zh_female_vv_uranus_bigtts';

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

  ScriptDoc threeLines() => ScriptDoc([
        ScriptLine(id: 'l1', text: '第一句'),
        ScriptLine(id: 'l2', text: '第二句'),
        ScriptLine(id: 'l3', text: '第三句'),
      ]).withDefaultVoiceId(voiceId);

  LineVoiceover doneVoiceover(String text) => LineVoiceover(
        audioPath: '${voices.path}/别人配的.mp3',
        durationMs: 1500,
        sourceText: text,
        voiceId: voiceId,
        speechRate: 0,
      );

  test('另一个进程在这期间配完了后两句——这一轮不再为它们付钱', () async {
    final repo = FileTaskRepository(dir);
    await repo.save(taskWith(threeLines()));

    final spoken = <String>[];
    final log = StringBuffer();
    final out = StringBuffer();
    final code = await runScriptVoiceCommand(
      rest: const ['sc1'],
      dataDir: dir,
      out: out,
      err: log,
      voiceFactory: (task) => LineVoiceService(
        tts: _FakeTts(spoken, onFirst: () async {
          // 第 1 句正在合成的这几分钟里，另一个进程把后两句配完落了盘
          final now = await repo.findById('sc1');
          final doc = now!.script!
              .setVoiceoverById('l2', doneVoiceover('第二句'))
              .setVoiceoverById('l3', doneVoiceover('第三句'));
          await repo.save(now.copyWith(
              script: doc, updatedAt: DateTime.now()));
        }),
        outputDir: voices,
        measureMs: (f) async => 1500,
      ),
    );

    expect(code, 0);
    expect(spoken, ['第一句'],
        reason: '第 2、3 句盘上已经有配音了，再念一遍就是再收一次费');
    expect(log.toString(), contains('第 2 句已经有配音了，跳过'));
    expect(log.toString(), contains('第 3 句已经有配音了，跳过'));
    expect(out.toString(), contains('"skipped":2'),
        reason: '跳过几句要报给调用方——不然一轮全跳过和一轮全新配长得一模一样');
  });

  /// **逐句的重读守卫只挡得住「对方跑在前面」那一半。**
  ///
  /// 推演「命令超时了又起一个」这个主场景：进程 1 跑到第 12 句，进程 2 起来，
  /// 跳过 1–11（那一半守住了），**从第 12 句开始**。两个都重读、都看到第 12
  /// 句还不是 fresh（进程 1 还没合成完）→ **都调 TTS**；写完各自进第 13 句……
  /// 剩下十几句全部念两遍。
  ///
  /// 所以命令级还要有一道：发现另一个进程正在给这条任务配音，就什么都不做、
  /// 如实说一句、给出 `--force`。**这是劝告不是拒绝**——退出码 0，决定权
  /// 仍在 Agent 手上。
  test('另一个进程正在给这条任务配音：这一轮不跑，但退出码 0 并说清出路', () async {
    await FileTaskRepository(dir).save(taskWith(threeLines()));
    writeAgentPresence(
      dataDir: dir,
      taskId: 'sc1',
      presence: AgentPresence(
          holder: 'agent:另一个会话',
          at: DateTime.now(),
          action: '正在给第 2 句配音（2/3）'),
    );

    final spoken = <String>[];
    final out = StringBuffer();
    final code = await runScriptVoiceCommand(
      rest: const ['sc1'],
      dataDir: dir,
      out: out,
      err: StringBuffer(),
      voiceFactory: (task) => LineVoiceService(
        tts: _FakeTts(spoken), outputDir: voices, measureMs: (f) async => 1500),
    );

    expect(code, 0, reason: '这是劝告，不是拒绝——软件不对 Agent 说「不行」');
    expect(spoken, isEmpty, reason: '一句都不许念——那是重复收费');
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json['skipped'], isTrue,
        reason: 'Agent 是按 JSON 判断的，只在 stderr 说一句它读不到');
    expect(json['reason'], contains('另一个进程正在配音'));
    expect(json['hint'], contains('--force'), reason: '出路必须给出来');
  });

  test('给了 --force：照常配，不再跳过', () async {
    await FileTaskRepository(dir).save(taskWith(threeLines()));
    writeAgentPresence(
      dataDir: dir,
      taskId: 'sc1',
      presence: AgentPresence(
          holder: 'agent:另一个会话',
          at: DateTime.now(),
          action: '正在给第 2 句配音（2/3）'),
    );

    final spoken = <String>[];
    final code = await runScriptVoiceCommand(
      rest: const ['sc1'],
      dataDir: dir,
      force: true,
      out: StringBuffer(),
      err: StringBuffer(),
      voiceFactory: (task) => LineVoiceService(
        tts: _FakeTts(spoken), outputDir: voices, measureMs: (f) async => 1500),
    );

    expect(code, 0);
    expect(spoken, ['第一句', '第二句', '第三句'], reason: '--force 就是照跑');
  });

  test('别人在这条任务上干的是别的活（挑镜头）：不拦', () async {
    await FileTaskRepository(dir).save(taskWith(threeLines()));
    writeAgentPresence(
      dataDir: dir,
      taskId: 'sc1',
      presence: AgentPresence(
          holder: 'agent:另一个会话',
          at: DateTime.now(),
          action: '正在给第 3 句挑镜头'),
    );

    final spoken = <String>[];
    final code = await runScriptVoiceCommand(
      rest: const ['sc1'],
      dataDir: dir,
      out: StringBuffer(),
      err: StringBuffer(),
      voiceFactory: (task) => LineVoiceService(
        tts: _FakeTts(spoken), outputDir: voices, measureMs: (f) async => 1500),
    );

    expect(code, 0);
    expect(spoken, hasLength(3), reason: '挑镜头跟配音撞不上，拦它是白拦');
  });

  test('重跑一整条命令：已经配好的那些一句都不会重念', () async {
    final repo = FileTaskRepository(dir);
    final doc = threeLines()
        .setVoiceoverById('l1', doneVoiceover('第一句'))
        .setVoiceoverById('l2', doneVoiceover('第二句'));
    await repo.save(taskWith(doc));

    final spoken = <String>[];
    final code = await runScriptVoiceCommand(
      rest: const ['sc1'],
      dataDir: dir,
      out: StringBuffer(),
      err: StringBuffer(),
      voiceFactory: (task) => LineVoiceService(
        tts: _FakeTts(spoken),
        outputDir: voices,
        measureMs: (f) async => 1500,
      ),
    );

    expect(code, 0);
    expect(spoken, ['第三句'], reason: '被 kill 之后重跑，只该补没配完的那些');
  });
}

class _FakeTts implements TtsClient {
  final List<String> spoken;

  /// 第一次合成时顺手模拟「另一个进程把后面几句配完了」
  final Future<void> Function()? onFirst;

  _FakeTts(this.spoken, {this.onFirst});

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String speaker,
    String? instruction,
    int? speechRate,
    String resourceId = TtsClient.presetResource,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final first = spoken.isEmpty;
    spoken.add(text);
    if (first && onFirst != null) await onFirst!();
    return TtsResult(audio: Uint8List(64), words: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'dart:io';

import '../../core/ai/volcano_asr_provider.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/script_service_wiring.dart';
import '../../core/script/uploaded_voice.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_seq.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_lock_holder.dart';
import '../agent_stage.dart';
import '../cli_output.dart';
import '../lock_yield.dart';
import 'analyze_command.dart' show loadCliCredentials;

/// `ishkafel script voice-file <任务> --line N <音频文件>` ——
/// **用我自己录的配音**。
///
/// 为什么要有这条路：合成语音的情绪天花板就摆在那儿（预置音色、句与句之间
/// 没有上下文）。原片那个人激动地在争吵，合成出来还是平的。与其继续磨参数，
/// 不如让人自己念——念成什么样就是什么样。
///
/// 这条线的时间根是配音时长，所以人录了多长，这一行就有多长；镜头分配、
/// 断句、字幕打轴全部从这段录音重新长出来。
///
/// **音频里说的和脚本里写的不一样时，以音频为准**：人已经念出来了，那就是
/// 事实，改脚本去将就音频，而不是反过来要求人重录。
Future<int> runScriptVoiceFileCommand({
  required List<String> rest,
  required Directory dataDir,
  int? line,
  String? holder,

  /// 可视模式：界面跟到这一行，人看着自己的录音装上去
  bool? visual,

  /// 测试注入：量时长 / 转写。真机走 ffmpeg + ASR
  Future<int> Function(File audio)? measureMs,
  Future<List<VoiceWord>> Function(File audio)? transcribe,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.length < 2) {
    sink.writeln('用法：ishkafel script voice-file <任务 id> --line <行号> <音频文件>');
    return exitBadUsage;
  }
  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, rest.first);
  if (task == null) {
    sink.writeln('没有这个任务：${rest.first}');
    return exitNotFound;
  }
  final doc = task.script;
  if (doc == null) {
    sink.writeln('「${task.name}」不是脚本成片任务');
    return exitBadUsage;
  }
  if (line == null || line < 1 || line > doc.lines.length) {
    sink.writeln('要指定行号：--line <行号>（1~${doc.lines.length}）');
    return exitBadUsage;
  }
  final source = File(rest[1]);
  if (!source.existsSync()) {
    sink.writeln('找不到这个音频文件：${rest[1]}');
    return exitBadUsage;
  }

  final index = line - 1;
  final target = doc.lines[index];
  if (target.type != ScriptLineType.voiced) {
    sink.writeln('第 $line 行是画面行（没有台词），不需要配音。');
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!await acquireYieldingFromUi(
      lock: lock,
      holder: holder ?? agentLockHolder,
      dataDir: dataDir,
      taskId: task.id,
      onWait: sink.writeln)) {
    sink.writeln('等了很久，这个任务一直被「${lock.read()?.holder ?? '别人'}」占着，'
        '先不动它了。');
    return exitLocked;
  }
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? agentLockHolder,
  );
  final focus =
      AgentFocus(module: 'director', lineIndex: index, panel: AgentPanel.voice);
  await stage.begin('正在装第 $line 行的录音', focus: focus);
  try {
    // **把音频收进任务名下**：人给的那个文件随时可能被移走、改名、删掉，
    // 而它现在是这一行的时间根——留在外面等于把成片的地基放在别人家里
    final kept = await keepUploadedVoice(
        source: source,
        dataDir: dataDir,
        taskId: task.id,
        lineId: target.id);

    final durationMs = await (measureMs ?? measureAudioMs)(kept);
    if (durationMs <= 0) {
      sink.writeln('这个音频读不出时长，可能不是能用的音频文件。');
      return exitFailed;
    }

    // 逐字时间戳是断句和字幕打轴的依据，没有它这一行只能整句糊一屏
    sink.writeln('· 正在听这段录音说了什么');
    await stage.show('正在听第 $line 行这段录音说了什么', focus: focus);
    List<VoiceWord> words = const [];
    var heard = '';
    try {
      final fn = transcribe ??
          () {
            final credentials = loadCliCredentials(dataDir);
            if (credentials.speechAppId.isEmpty) return null;
            final asr = VolcanoAsrProvider(
              appId: credentials.speechAppId,
              accessToken: credentials.speechAccessToken,
            );
            return (File a) => transcribeVoiceWords(asr, a);
          }();
      if (fn == null) {
        sink.writeln('缺少语音凭据，听不出这段录音说了什么——'
            '时长会用上，但**断不了句、字幕只能整句一屏**，台词也不会跟着改。');
      } else {
        words = await fn(kept);
        heard = words.map((w) => w.text).join();
      }
    } catch (e) {
      // 不静默：听不出来只影响断句，不该挡住「用我自己的配音」这件事
      sink.writeln('这段录音没听清（$e）——时长照用，但断不了句。');
    }

    final beforeText = target.text.trim();
    final updated = await TaskMutation(
      repo: repository,
      dataDir: dataDir,
      by: ActorKind.agent,
      actor: 'Agent',
    ).apply(
      taskId: task.id,
      op: 'voice.upload',
      where: {'line': line},
      edit: (fresh) {
        final freshDoc = fresh.script;
        if (freshDoc == null) throw StateError('这条任务的脚本没了：${task.id}');
        final applied = applyUploadedVoice(
          doc: freshDoc,
          lineIndex: index,
          audioPath: kept.path,
          durationMs: durationMs,
          words: words,
          heardText: heard,
        );
        return TaskEdit(
          task: fresh.copyWith(script: applied),
          before: {
            'text': freshDoc.lines.length > index
                ? freshDoc.lines[index].text.trim()
                : beforeText,
            'durationMs': freshDoc.lines.length > index
                ? freshDoc.lines[index].voiceover?.durationMs
                : null,
          },
          after: {'text': applied.lines[index].text.trim(), 'durationMs': durationMs},
        );
      },
    );
    if (updated == null) {
      sink.writeln('这条任务在操作过程中被删掉了：${task.id}');
      return exitNotFound;
    }
    // 这一行的时长换了根，镜头分配跟着变——让人当场看见落到哪一行
    await stage.show('第 $line 行换成你自己的录音了（${durationMs}ms）',
        focus: focus);

    final next = updated.script!;
    final before = beforeText;
    final after = next.lines[index].text.trim();
    if (after != before) {
      // 台词一改，按字划出来的分镜就不成立了（字的位置全变了）——说出来
      final boundShots =
          target.shots.where((s) => s.boundToWords).length;
      sink.writeln('台词按你录的改了：\n  原来：$before\n  现在：$after'
          '${boundShots > 0 ? '\n  这一行有 $boundShots 个按字划出来的分镜，'
              '字的位置变了，去看一眼还成不成立' : ''}');
    }
    emitJson({
      'ok': true,
      'taskId': task.id,
      'line': line,
      'durationMs': durationMs,
      'words': words.length,
      'text': after,
      if (after != before) 'textChangedFrom': before,
      'next': words.isEmpty
          ? '这一行没有逐字时间，断不了句；补上语音凭据后重传一次就有了'
          : 'ishkafel script subtitles ${task.id} --line $line（看看要不要断句）',
    }, out: out);
    return 0;
  } finally {
    // 收工要撤在场状态，否则界面会一直显示「Agent 正在操作」，人动不了手
    stage.end();
    lock.release(holder ?? agentLockHolder);
  }
}

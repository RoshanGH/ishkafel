import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../app/service_wiring.dart';
import '../../core/ai/ai_credentials.dart';
import '../../core/analysis/tag_vocabulary.dart';
import '../../core/miaoa/miaoa_locator.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/models/renew_task.dart';
import '../external_steps.dart';
import '../todo_view.dart';
import '../cli_output.dart';
import '../task_view.dart';

/// `ishkafel analyze <task>`
///
/// 跑完整分析：抽音频 → 分离 → ASR → 语义切分 → 场景检测 → 打标 → 建单元。
///
/// **这一版全部走内置 AI**。把其中几步外包给调用方（`--external`）是下一步
/// 的事，边界见 spec 第三节：能外包的是输出可验证的那几步（语义切分、打标、
/// 切点矫正），ASR 不行——它的时间戳偏 200ms 就毁掉整条链，而且不会报错。
Future<int> runAnalyzeCommand({
  required List<String> rest,
  required Directory dataDir,
  String? external,
  String holder = 'agent',
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel analyze <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;

  final repository = FileTaskRepository(dataDir);
  final task = await repository.findById(id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  final parsedExternal = parseExternal(external);
  if (parsedExternal.unknown.isNotEmpty) {
    // 不能静默忽略：调用方会以为外包生效了，其实还在烧内置 API
    sink.writeln('认不出这些步骤：${parsedExternal.unknown.join('、')}。'
        '可外包的只有 segment、tag——'
        'ASR 不可外包，它的时间戳没法验证，偏 200ms 就毁掉整条链');
    return exitBadUsage;
  }
  final external0 = parsedExternal.steps;

  final credentials = loadCliCredentials(dataDir);
  if (!credentials.isComplete) {
    // 这里必须说清楚怎么办：CLI 是单独编译的，GUI 那份 --dart-define 编进去
    // 的凭据带不过来
    sink.writeln('缺少 AI 凭据，无法分析。把 ark_api_key / speech_app_id / '
        'speech_access_token 三个文件放到：\n'
        '  ${p.join(dataDir.path, 'credentials')}/\n'
        '或者用环境变量 ARK_API_KEY / SPEECH_APP_ID / SPEECH_ACCESS_TOKEN');
    return 1;
  }

  final pipeline = buildAnalysisPipeline(credentials, dataDir);
  if (pipeline == null) {
    sink.writeln('分析流水线装配失败（凭据不完整）');
    return 1;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: id);
  if (!lock.acquire(holder)) {
    sink.writeln('${lock.read()?.holder ?? '别人'} 正在操作这个任务，分析不了');
    return exitLocked;
  }
  // 分析要跑好几分钟，中途得续命，否则锁会在 60 秒后被判失效
  final heartbeat =
      Timer.periodic(const Duration(seconds: 20), (_) => lock.heartbeat(holder));

  try {
    if (external0.isEmpty) {
      final analyzed = await pipeline.analyze(
        task,
        onProgress: (progress) => sink.writeln('· ${progress.stage.name}'),
      );
      if (analyzed.analysisError case final failure?) {
        sink.writeln('分析失败：$failure');
        return 1;
      }
      emitJson(taskToJson(analyzed), out: out);
      return 0;
    }

    // 有要外包的步骤：先把不可外包的前半程跑完（抽音频、分离、镜头切点、
    // ASR），落盘，然后把第一件待办交出去
    final prepared = await pipeline.prepare(
      task,
      onProgress: (progress) => sink.writeln('· ${progress.stage.name}'),
    );
    saveAnalysisState(dataDir, id,
        AnalysisState(prepared: prepared, pending: external0));
    await repository.save(task.copyWith(
      asrSentences: prepared.sentences,
      vocalsPath: prepared.vocalsPath,
      backgroundPath: prepared.backgroundPath,
    ));

    if (external0.contains(ExternalStep.segment)) {
      emitJson(segmentTodo(id, prepared.sentences), out: out);
      return 0;
    }

    // 只外包打标：切分照常走内置，跑到「等你打标」那一步
    final drafts = await pipeline.splitter.split(prepared.sentences);
    final units =
        pipeline.assemble(task: task, drafts: drafts, prepared: prepared);
    final ready = task.copyWith(
      units: units,
      status: RenewTaskStatus.ready,
      asrSentences: prepared.sentences,
      vocalsPath: prepared.vocalsPath,
      backgroundPath: prepared.backgroundPath,
    );
    await repository.save(ready);
    emitJson(
      tagTodo(
        id,
        ready,
        unitVocabulary: await vocabularyFor(ready.unitTagGroups),
        shotVocabulary: await vocabularyFor(ready.shotTagGroups),
      ),
      out: out,
    );
    return 0;
  } catch (e) {
    sink.writeln('分析失败：$e');
    return 1;
  } finally {
    heartbeat.cancel();
    lock.release(holder);
  }
}

/// 这些标签组下的**标签**（不是组名）。
///
/// 打标的受控词表就是它。给错了调用方会打出一批全被拒绝的标签，而它无从
/// 知道自己错在哪。
Future<List<String>> vocabularyFor(List<TagGroupRef> groups) async {
  final source =
      MiaoaTagVocabularySource(MiaoaTagService(binary: resolveMiaoaBinary()));
  final all = <String>{};
  for (final group in groups) {
    all.addAll(await source.vocabularyOf(group.id));
  }
  return all.toList()..sort();
}

/// CLI 的凭据来源。
///
/// **和 GUI 不是一回事**：GUI 那份是 `--dart-define` 在编译期注入的，而 CLI
/// 是单独编译的二进制，带不过来。所以只能从环境变量或凭据目录读——读不到时
/// 上面会把该放哪儿说清楚，而不是让分析跑到一半报一个 401。
AiCredentials loadCliCredentials(Directory dataDir) =>
    CredentialsLoader.load(secretsDirs: [
      Directory(p.join(dataDir.path, 'credentials')),
      Directory(p.join(Directory.current.path, '.secrets')),
    ]);

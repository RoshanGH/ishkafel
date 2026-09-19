import 'dart:io';

import 'package:path/path.dart' as p;

import '../app_locator.dart';

import '../../app/service_wiring.dart';
import '../../core/ai/ai_credentials.dart';
import '../../core/analysis/analysis_pipeline.dart';
import '../../core/analysis/tag_vocabulary.dart';
import '../../core/miaoa/miaoa_tag_service.dart';
import '../../core/models/tag_group_ref.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/models/renew_task.dart';
import '../../core/storage/task_seq.dart';
import '../external_steps.dart';
import '../todo_view.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import '../busy_guard.dart';
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
  String? holder,

  /// 可视模式：分析要跑好几分钟，人得看着它一步步走到哪儿了
  bool? visual,

  /// 已经有人在分析这条任务时照样再跑一遍。见 `busy_guard.dart`
  bool force = false,
  StringSink? out,
  StringSink? err,

  /// 测试注入：判「有没有人正在分析」时的当前时刻
  DateTime? now,

  /// 测试注入：不给就按凭据装配真实管线（与 script 那几条同一种做法）
  AnalysisPipeline? pipeline,
}) async {
  final sink = err ?? stderr;
  if (rest.isEmpty) {
    sink.writeln('用法：ishkafel analyze <任务 id>');
    return exitBadUsage;
  }
  final id = rest.first;

  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  // 空白任务没有原片。让它往下走的话，报出来的是一句带 "Bad state:" 前缀的
  // 异常文本——那是给程序员看的
  if (task.isBlank) {
    sink.writeln('$id 是一条空白任务，没有原片可分析。'
        '用 blank tags 给分子打标签，然后直接 candidates / apply plans / export');
    return exitBadUsage;
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
    return exitEnv;
  }

  final line = pipeline ?? buildAnalysisPipeline(credentials, dataDir);
  if (line == null) {
    sink.writeln('分析流水线装配失败（凭据不完整）');
    return exitEnv;
  }

  // **别把同一条管线跑两遍。**
  //
  // 整条分析是 ASR + LLM 切分 + 逐镜打标，几分钟、真金白银。而「调用方的
  // 命令超时了、以为失败又起一个」在真机上是常态——此前挡住这件事的是
  // 任务锁（第二个进程撞锁退出），锁删掉之后得有别的东西接住它。
  //
  // 配音、打标那种循环能把幂等落到每一项上（每一句/每一镜开工前重读盘，
  // 做过的跳过）；分析不行，它是一整条管线，没有「项」可跳。
  //
  // **所以这里给的是劝告，不是拒绝**——这一条一定要分清楚：
  //
  // - 退出码是 0，不是失败
  // - 报的是**事实**（「另一个进程正在分析，我没有重复做」），不是规则
  // - `--force` 这条明路就写在输出里，决定权仍在调用方手上
  //
  // 产品负责人的原话：「任何它不应该做的事情，都应该是人告诉 Agent 的，
  // 而非是软件限制的。」给事实和出路，不给规则。
  if (!force) {
    final busy = someoneElseBusyWith(
        dataDir: dataDir,
        taskId: task.id,
        keywords: const [analyzeBusyKeyword],
        now: now);
    if (busy != null) {
      emitJson(
          busySkipReport(
              taskId: task.id, busy: busy, what: analyzeBusyKeyword),
          out: out);
      return 0;
    }
  }

  // 分析要跑好几分钟，是这条线上最长的一段等待——**每一步都要说出来**，
  // 不然人对着一块不动的板子不知道它是在跑还是卡死了
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? 'Agent',
  );
  // 「分析」两个字来自 busy_guard 那份常量：上面那道劝告认的就是它，
  // 手写的话改文案会让判据静默失效
  await stage.begin('正在$analyzeBusyKeyword原片',
      focus: const AgentFocus(module: 'workbench'));
  // **静默模式下 begin 什么都不做，在场状态还是要立刻写**：
  // 一来人可能正开着这一页，二来上面那道「别把同一条管线跑两遍」的劝告
  // 认的就是它——不在这儿写，第二个进程要等到第一次进度回调才看得见，
  // 而 prepare 那一段（抽音频、分离）好几分钟里它什么都看不见
  stage.note('正在$analyzeBusyKeyword原片',
      focus: const AgentFocus(module: 'workbench'));

  try {
    if (external0.isEmpty) {
      final analyzed = await line.analyze(
        task,
        // 这一趟是 Agent 叫起来的——管线两边共用，谁触发算谁的
        by: ActorKind.agent,
        actor: 'Agent',
        onProgress: (progress) {
          sink.writeln('· ${progress.stage.name}');
          stage.note('正在$analyzeBusyKeyword原片：${progress.stage.name}',
              focus: const AgentFocus(module: 'workbench'));
        },
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
    final prepared = await line.prepare(
      task,
      onProgress: (progress) {
        sink.writeln('· ${progress.stage.name}');
        stage.note('正在$analyzeBusyKeyword原片：${progress.stage.name}',
            focus: const AgentFocus(module: 'workbench'));
      },
    );
    saveAnalysisState(dataDir, id,
        AnalysisState(prepared: prepared, pending: external0));
    final mutation = TaskMutation(
        repo: repository, dataDir: dataDir, by: ActorKind.agent, actor: 'Agent');
    final prepped = await mutation.apply(
      taskId: task.id,
      op: 'analyze.prepare',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(
          asrSentences: prepared.sentences,
          vocalsPath: prepared.vocalsPath,
          backgroundPath: prepared.backgroundPath,
        ),
        before: {'sentenceCount': fresh.asrSentences?.length ?? 0},
        after: {'sentenceCount': prepared.sentences.length},
      ),
    );
    if (prepped == null) {
      sink.writeln('这条任务在分析过程中被删掉了：$id');
      return exitNotFound;
    }

    if (external0.contains(ExternalStep.segment)) {
      emitJson(segmentTodo(id, prepared.sentences), out: out);
      return 0;
    }

    // 只外包打标：切分照常走内置，跑到「等你打标」那一步。
    // 语义切分是网络请求，做完拿到 drafts 再进第二次独立的 apply——
    // 不能塞进上面那次 edit，重跑一次 edit 就是把切分又算一遍
    final drafts = await line.splitter.split(prepared.sentences);
    final units =
        line.assemble(task: task, drafts: drafts, prepared: prepared);
    final ready = await mutation.apply(
      taskId: task.id,
      op: 'units.assemble',
      edit: (fresh) => TaskEdit(
        task: fresh.copyWith(
          units: units,
          status: RenewTaskStatus.ready,
          asrSentences: prepared.sentences,
          vocalsPath: prepared.vocalsPath,
          backgroundPath: prepared.backgroundPath,
        ),
        before: {'unitCount': fresh.units?.length ?? 0, 'status': fresh.status.name},
        after: {'unitCount': units.length, 'status': RenewTaskStatus.ready.name},
      ),
    );
    if (ready == null) {
      sink.writeln('这条任务在切分过程中被删掉了：$id');
      return exitNotFound;
    }
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
    stage.end();
  }
}

/// 这些标签组下的**标签**（不是组名）。
///
/// 打标的受控词表就是它。给错了调用方会打出一批全被拒绝的标签，而它无从
/// 知道自己错在哪。
Future<List<String>> vocabularyFor(List<TagGroupRef> groups) async {
  final source =
      MiaoaTagVocabularySource(MiaoaTagService());
  final all = <String>{};
  for (final group in groups) {
    all.addAll(await source.vocabularyOf(group.id));
  }
  return all.toList()..sort();
}

/// CLI 的凭据来源。
///
/// GUI 那份是 `--dart-define` 在编译期注入的，而 `dart build cli` 压根不认
/// 这个参数，所以 CLI 只能从文件读。正式包会把同一份凭据拷进
/// `<app>/Contents/Resources/cli/credentials/`，CLI 从自己的路径回推着读——
/// 拿到正式包的人不用配任何东西，Agent 也能直接开工。
/// 顺序见 [cliSecretsDirs]：人手动放的能盖掉包里自带的。
AiCredentials loadCliCredentials(Directory dataDir) =>
    CredentialsLoader.load(secretsDirs: cliSecretsDirs(dataDir: dataDir));

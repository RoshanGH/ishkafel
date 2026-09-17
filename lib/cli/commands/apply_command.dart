import 'dart:convert';
import '../../core/analysis/tag_merge.dart';
import '../../core/models/semantic_unit.dart';
import 'dart:io';
import '../frame_check_wiring.dart';

import 'package:path/path.dart' as p;

import '../../core/storage/file_task_repository.dart';
import '../../app/service_wiring.dart';
import '../../core/models/renew_task.dart';
import '../../core/storage/task_log.dart';
import '../../core/storage/task_mutation.dart';
import '../../core/storage/task_seq.dart';
import '../external_steps.dart';
import '../task_view.dart';
import '../todo_view.dart';
import 'analyze_command.dart';
import '../../core/miaoa/candidate_probe.dart';
import '../../core/ai/frame_check.dart';
import '../../core/replacement/brand_consistency.dart';
import '../../core/replacement/picked_material.dart';
import '../../core/replacement/replacement_plan.dart';
import '../../core/replacement/unit_base.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/ffmpeg/process_runner.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/agent_presence.dart';
import '../agent_stage.dart';
import '../../core/storage/agent_request.dart';
import '../../core/storage/ui_action.dart';
import '../cli_output.dart';
import '../delegate.dart';
import '../plan_submission.dart';

/// `ishkafel apply plans <task> --file <json>`（也支持从 stdin 读）
///
/// 收下 Agent 提交的方案列表，**过校验**之后落盘，供 `export` 使用。
///
/// 校验不过就整批拒绝并一次点全所有问题——让它改一个提交一次是在浪费双方
/// 的时间。外包出去的是「判断」，不是「数据结构的定义权」（spec 第三节）。
Future<int> runApplyCommand({
  required List<String> rest,
  required Directory dataDir,

  /// 测试注入；真机走真实的 miaoa CLI
  MiaoaContentService? contentService,
  CandidateProbe? candidateProbe,
  String? file,
  String? holder,

  /// 可视模式：切分、打标、方案落进界面时人看着它一条条进去
  bool? visual,
  Future<String> Function()? readStdin,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  if (rest.length < 2) {
    sink.writeln('用法：ishkafel apply plans|segment|tags <任务 id> --file <x.json>');
    return exitBadUsage;
  }
  final what = rest.first;
  const supported = {'plans', 'segment', 'tags'};
  if (!supported.contains(what)) {
    sink.writeln('认不出「$what」。可用：${supported.join(' / ')}');
    return exitBadUsage;
  }
  final id = rest[1];

  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }

  // **提交方案一律走委派这条路。**
  //
  // 「人在界面上看着」曾经是这一步的障碍：界面占着锁，而提交方案恰恰是
  // 最该让人看见的一步（成片长什么样就是它定的），于是最该看的时候反而
  // 做不了，给出的出路还是「让人别看」。现在反过来——界面在这条任务上
  // 就请它代办（人看着方案落进去），不在就零等待自己写。
  // 两条路落的是同一份 `_commitPlans`，不会有第二套算法。
  if (what == 'plans') {
    return _applyPlansViaUi(
      dataDir: dataDir,
      task: task,
      file: file,
      readStdin: readStdin,
      sink: sink,
      out: out,
      contentService: contentService,
      candidateProbe: candidateProbe,
    );
  }

  return _applyDirect(
    what: what,
    id: id,
    task: task,
    file: file,
    readStdin: readStdin,
    dataDir: dataDir,
    repository: repository,
    sink: sink,
    out: out,
    visual: visual,
    holder: holder,
  );
}

/// `segment` / `tags`：外包出去的**判断**回填进来。
///
/// `plans` 不走这里——它统一走 [_applyPlansViaUi]（界面在就委派、不在就
/// 自己写），**收素材与画面自查因此物理上只有一处**
Future<int> _applyDirect({
  required String what,
  required String id,
  required RenewTask task,
  required String? file,
  required Future<String> Function()? readStdin,
  required Directory dataDir,
  required FileTaskRepository repository,
  required StringSink sink,
  required StringSink? out,
  bool? visual,
  String? holder,
}) async {
  final String raw;
  try {
    raw = file == null
        ? await (readStdin ?? _readStdin)()
        : File(file).readAsStringSync();
  } catch (e) {
    sink.writeln('读不到方案文件：$e');
    return exitBadUsage;
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    sink.writeln('提交的内容不是合法的 JSON：$e');
    return exitBadUsage;
  }

  // 切分和打标都是**外包出去的判断回填进来**——落到哪几个单元上，
  // 人得看着它一条条进去，而不是命令说了句「好了」
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? 'Agent',
  );
  if (what == 'segment') {
    await stage.begin('正在应用切分',
        focus: const AgentFocus(module: 'workbench'));
    try {
      return await _applySegment(
          decoded, task, dataDir, repository, sink, out ?? stdout);
    } finally {
      stage.end();
    }
  }
  await stage.begin('正在应用标签',
      focus: const AgentFocus(module: 'workbench'));
  try {
    return await _applyTags(
        decoded, task, dataDir, repository, sink, out ?? stdout);
  } finally {
    stage.end();
  }
}

/// 落盘方案：**直写路径**（界面不在这条任务上）和**委派兜底**（界面在、
/// 但没跟上）共用同一份——避免同一件事两处算
Future<int> _commitPlans({
  required Directory dataDir,
  required RenewTask task,
  required FileTaskRepository repository,
  required String raw,
  required List<SubmittedPlan> plans,
  required List<PickedMaterial> picked,
  required StringSink sink,
  required StringSink? out,
}) async {
  _writePlans(dataDir, task.id, raw);
  final units = task.units ?? const <SemanticUnit>[];
  final replacements = projectPlansToReplacements(plans, units);

  // 同步投影成任务的替换现状：审核页读的是它——不投影的话，
  // 纯 CLI 流程里 `ishkafel review` 永远无东西可审（真机踩过）。
  //
  // **按 uid 合并，不整份替换**（2026-09-17 评审纠正：整份替换的理由
  // 「按 uid 合并会让人删过的方案复活」站不住——整份替换同样会让它复活
  // （byUid 里那条旧方案照样在），而且额外还会抹掉人在这段窗口里给
  // 新单元建的方案。按 uid 合并再按 fresh 的活 uid 过滤，在每一种情形下
  // 都不劣于整份替换，严格更好）：merge 完之后把 fresh 里已经不存在的
  // uid 过滤掉，不留孤儿方案。pickedMaterials 同理按素材 id 合并。
  final byUid = RenewTask.byUid(units, replacements);
  final updated = await TaskMutation(
    repo: repository,
    dataDir: dataDir,
    by: ActorKind.agent,
    actor: 'Agent',
  ).apply(
    taskId: task.id,
    op: 'plans.apply',
    edit: (fresh) {
      final liveUids = {for (final u in fresh.units ?? const []) u.uid};
      final mergedReplacements = {...fresh.replacementsByUid, ...byUid}
        ..removeWhere((uid, _) => !liveUids.contains(uid));
      final mergedPicked = {
        for (final m in fresh.pickedMaterials) m.id: m,
        for (final m in picked) m.id: m,
      }.values.toList();
      return TaskEdit(
        task: fresh.copyWith(
          replacementsByUid: mergedReplacements,
          pickedMaterials: mergedPicked,
        ),
        before: {
          'replacedUnits': fresh.replacementsByUid.length,
          'materials': fresh.pickedMaterials.length,
        },
        after: {
          'replacedUnits': mergedReplacements.length,
          'materials': [
            for (final m in picked)
              {
                'id': m.id,
                'name': m.name,
                'sceneDescription': m.sceneDescription,
                'durationMs': m.durationMs,
                'burnedText': m.burnedText,
                'productBrand': m.productBrand,
              },
          ],
        },
      );
    },
  );
  if (updated == null) {
    sink.writeln('这条任务在提交方案的过程中被删掉了：${task.id}');
    return exitNotFound;
  }
  emitJson({
    'ok': true,
    ...planApplyReport(
        plans: plans,
        picked: picked,
        task: updated,
        shortSlots: shortSlotsOf(updated)),
  }, out: out);
  return 0;
}

/// 把方案里用到的素材连同**时长**和**画面自查**一起收下来。
///
/// **倍速全靠时长**：20 秒的素材塞进 0.5 秒的坑位，得先知道它是 20 秒，
/// 才算得出这一镜要放 40 倍。
///
/// **画面自查是烧字 + 产品露出品牌**：两样都只有看图才发现得了，而且都会
/// 毁掉整片——烧着别家字幕的素材换上去成片出现两层字，露着竞品的素材会让
/// 台词说滴露而画面是若也。
///
/// 单独提出来是因为 `apply plans` 有**两条路**（界面没开时 CLI 直写、
/// 界面开着时委派给界面），两条路都得收。委派那条一度不收——于是出现了
/// 最难发现的组合：**人在旁边看着的时候，检查反而不做**。
/// 提交方案之后要告诉调用方的一切。
///
/// **两条路（直写 / 委派）共用这一份**。分开写的后果验收 Agent 撞到过：
/// 委派返回只有 `{ok, via, message, plans, units}`——检查跑了、界面上也
/// 报了那条橙色警告，**只有 Agent 拿不到**。它的原话：「不是『人能干的事
/// Agent 干不了』，是**人能看到的信息 Agent 拿不到**。」
///
/// 而且它试了四种条件也没找出什么时候走哪条路——**同一条命令的返回结构
/// 在同样的表面条件下会变**，那样「拿到 burnedText 就换素材」这段逻辑
/// 根本没法写。
Map<String, Object?> planApplyReport({
  required List<SubmittedPlan> plans,
  required List<PickedMaterial> picked,
  required RenewTask task,
  required int shortSlots,
}) {
  final withDuration = picked.where((m) => (m.durationMs ?? 0) > 0).length;
  return {
    'plans': [
      for (final plan in plans) {'name': plan.name, 'units': plan.units.length},
    ],
    'materials': {
      'count': picked.length,
      'withDuration': withDuration,
      // **「都干净」和「一条都没看成」得分得开**。只看 burnedText 在不在
      // 是分不清的：两种情况这个键都不出现，而一个是「没问题」、
      // 一个是「不知道有没有问题」
      'frameChecked': picked.where((m) => m.burnedTextChecked).length,
      'frameUnchecked': picked.where((m) => !m.burnedTextChecked).length,
    },
    // 影响成片的降级要说出来，不能等人拿到片子才发现有几镜在快放
    'notice': ?trimUnavailableNotice(
        total: picked.length, withDuration: withDuration, shortSlots: shortSlots),
    // 画面上本来就烧着字的那几条要点名——成片会出现两层字幕
    'burnedText': ?burnedTextNotice(picked),
    // 挑的素材里出现了不止一个品牌——台词说的和画面里摆的对不上。
    // 两条互补的判据：候选之间打架 / 候选一致但整条跑到别家去了
    'brandConflict': ?(brandConflictNotice(picked) ??
        brandMismatchNotice(
            picked: picked,
            sourceBrand: sourceBrandOf(task.units ?? const []))),
  };
}

/// 短坑位有几个：取段就是为它们做的，量不到时长时这些镜头会退回快进
int shortSlotsOf(RenewTask task) => [
      for (final u in task.units ?? const [])
        for (final shot in u.shots)
          if (shot.endMs - shot.startMs < 1500) shot,
    ].length;

/// 把共用的画面自查接成 `collectPickedMaterials` 要的形状。
/// 素材时长在 known 里就有——**传下去**，头中尾三个采样点按它算
Future<FrameCheck> Function(int id)? _wired(Directory dataDir, RenewTask task) {
  final check = defaultShotFrameCheck(dataDir: dataDir, taskId: task.id);
  if (check == null) return null;
  final knownMs = {
    for (final m in task.pickedMaterials)
      if (m.durationMs != null) m.id: m.durationMs!,
  };
  return (id) => check(id, knownMs[id]);
}

Future<List<PickedMaterial>> gatherPickedMaterials({
  required List<UnitReplacement> replacements,
  required RenewTask task,
  required Directory dataDir,
  MiaoaContentService? contentService,
  CandidateProbe? candidateProbe,
  Future<FrameCheck> Function(int id)? frameCheckOf,
}) async {
  // 规则在 [referencedCandidateIds] 里，**全仓只有那一份**——底片记在
  // 单元身上、不在方案里，漏掉它那条素材会被当孤儿清掉
  final used =
      referencedCandidateIds(task.units ?? const [], replacements);
  final content = contentService ?? MiaoaContentService();
  final probe = candidateProbe ??
      CandidateProbe(run: const ResolvingProcessRunner().call);
  final media = TaskMedia(dataDir: dataDir, taskId: task.id);
  return collectPickedMaterials(
    candidateIds: used,
    known: task.pickedMaterials,
    // 本地已经有这条素材时就不去问名字了：那是给人看的字段，
    // 而每问一次就是一次网络往返（102 条素材实测差出几十秒）
    fetch: (id) async =>
        media.localMaterial(id) != null ? null : content.fetchById(id),
    probeDurationMs: (id) async {
      // 素材已经下到本地就读本地：联网量一条要一秒，一百多条就是一百多秒，
      // 而且网络那条路会失败——失败了取段就退回快进
      final local = media.localMaterial(id);
      final m = local != null ? null : await content.fetchById(id);
      final spec = await probe.probe(
          materialId: id, previewUrl: m?.previewUrl, localPath: local);
      return spec?.durationMs ?? 0;
    },
    checkFrame: frameCheckOf ?? _wired(dataDir, task),
  );
}


/// 收下切分，组装成单元、落库，并把下一件待办交出去（如果还有）。
///
/// 这里只做**组装**，不做判断——怎么分组是调用方决定的，我们负责把它变成
/// 帧对齐的、和镜头切点吸附好的单元。
Future<int> _applySegment(
  Object? decoded,
  RenewTask task,
  Directory dataDir,
  FileTaskRepository repository,
  StringSink err,
  StringSink out,
) async {
  final state = readAnalysisState(dataDir, task.id);
  if (state == null) {
    err.writeln('没有待处理的分析状态。先跑 ishkafel analyze ${task.id} --external=segment');
    return exitNotFound;
  }

  final parsed = parseSegments(decoded, state.prepared.sentences);
  if (parsed.errors.isNotEmpty) {
    for (final problem in parsed.errors) {
      err.writeln('· $problem');
    }
    return exitBadUsage;
  }

  final credentials = loadCliCredentials(dataDir);
  final pipeline = buildAnalysisPipeline(credentials, dataDir);
  if (pipeline == null) {
    err.writeln('缺少 AI 凭据，无法组装单元');
    return 1;
  }

  // 组装是纯计算：drafts/prepared 都是已经拿到手的数据，没有 IO——
  // 可以放心整段塞进 TaskMutation 的 edit 闭包
  final units = pipeline.assemble(
      task: task, drafts: parsed.drafts, prepared: state.prepared);
  final mutation = TaskMutation(
      repo: repository, dataDir: dataDir, by: ActorKind.agent, actor: 'Agent');
  final ready = await mutation.apply(
    taskId: task.id,
    op: 'units.assemble',
    edit: (fresh) => TaskEdit(
      task: fresh.copyWith(
        units: units,
        status: RenewTaskStatus.ready,
        asrSentences: state.prepared.sentences,
        vocalsPath: state.prepared.vocalsPath,
        backgroundPath: state.prepared.backgroundPath,
      ),
      before: {'unitCount': fresh.units?.length ?? 0, 'status': fresh.status.name},
      after: {'unitCount': units.length, 'status': RenewTaskStatus.ready.name},
    ),
  );
  if (ready == null) {
    err.writeln('这条任务在应用切分的过程中被删掉了：${task.id}');
    return exitNotFound;
  }

  final stillPending = {...state.pending}..remove(ExternalStep.segment);
  saveAnalysisState(dataDir, task.id,
      AnalysisState(prepared: state.prepared, pending: stillPending));

  // 还欠打标就把下一件待办交出去；否则走内置打标收尾
  if (stillPending.contains(ExternalStep.tag)) {
    emitJson(
      tagTodo(
        task.id,
        ready,
        unitVocabulary: await vocabularyFor(ready.unitTagGroups),
        shotVocabulary: await vocabularyFor(ready.shotTagGroups),
      ),
      out: out,
    );
    return 0;
  }

  err.writeln('切分已应用（${units.length} 个单元），开始内置打标');
  // 打标是网络请求：做完拿到结果再进第二次独立的 apply，
  // 不能把它塞进上面那次 edit——重跑一次 edit 就是把打标又算一遍
  final tagged = await pipeline.tagging.tag(ready, units);
  final done = await mutation.apply(
    taskId: task.id,
    op: 'units.tag.auto',
    edit: (fresh) {
      // **合并标签，不整份替换单元**：tagged 是打标开始那一刻（ready）的
      // 快照打出来的结果，打标是分钟级的网络活儿——这段窗口里人在界面上
      // 拖过的边界、改过的台词、动过的镜头、手打的标签，如果整份换成
      // tagged 里对应的单元对象就会被悄悄盖回打标开始那一刻的旧版本。
      // 这正是 one_task_writer_test.dart 文档里五次事故的第一条：
      // 「管线打标 vs 工作台编辑：打标结束整份存回打标开始那一刻的快照，
      // 人在这七成时间里拖的边界全没了」——这里就是那个原型场景。
      //
      // 项目里已经有一份为这个场景写的合并：mergeTagsInto——按 uid 配对、
      // 边界一模一样才认（边界变过的单元这份标签是照旧边界打的，安上去
      // 就是错的）、当前已经有标签的不覆盖（人手改的比这份旧结果新）。
      // 不在这里另写一份更弱的合并——那正是这批改造要消灭的「同一件事
      // 两处算」。
      final freshUnits = fresh.units;
      // units 本来是 null（没分析过）时绝不能悄悄变成 []——那是另一个
      // 事实（task_mutation.dart 的 _stamp 对同一条原则也有一句注释）。
      // 正常流程走不到这里（上一次 apply 已经把 units 落成非空列表），
      // 纯防御
      if (freshUnits == null) {
        return TaskEdit(
          task: fresh,
          before: {'unitCount': 0},
          after: {'unitCount': 0, 'note': 'units 是 null（没分析过），无标签可合并'},
        );
      }
      final merged = mergeTagsInto(freshUnits, tagged);
      // 真正变了标签的 uid：跟 mergeTagsInto 判定「要不要真的动一下」
      // 用同一条判据（tag_merge.dart 导出的 unitTagsChanged）——不能只比
      // 单元级 tags，镜头标签是这次填上的、单元级 tags 没动（人手打过、
      // 不被覆盖）时也算「这个单元真的变了」，只看单元级会漏报
      final taggedUids = [
        for (var i = 0; i < freshUnits.length && i < merged.length; i++)
          if (unitTagsChanged(freshUnits[i], merged[i])) merged[i].uid,
      ];
      return TaskEdit(
        task: fresh.copyWith(units: merged),
        before: {'unitCount': freshUnits.length},
        after: {'unitCount': merged.length, 'taggedUnits': taggedUids},
      );
    },
  );
  if (done == null) {
    err.writeln('这条任务在打标的过程中被删掉了：${task.id}');
    return exitNotFound;
  }
  clearAnalysisState(dataDir, task.id);
  emitJson(taskToJson(done), out: out);
  return 0;
}

/// 收下标签并落库。标签必须在受控词表内——词表外的一律拒绝，不做近似匹配
Future<int> _applyTags(
  Object? decoded,
  RenewTask task,
  Directory dataDir,
  FileTaskRepository repository,
  StringSink err,
  StringSink out,
) async {
  final units = task.units;
  if (units == null) {
    err.writeln('这个任务还没有单元，先应用切分');
    return exitNotFound;
  }

  final parsed = parseTags(
    decoded,
    units,
    unitVocabulary: (await vocabularyFor(task.unitTagGroups)).toSet(),
    shotVocabulary: (await vocabularyFor(task.shotTagGroups)).toSet(),
  );
  if (parsed.errors.isNotEmpty) {
    for (final problem in parsed.errors) {
      err.writeln('· $problem');
    }
    return exitBadUsage;
  }

  final done = await TaskMutation(
    repo: repository,
    dataDir: dataDir,
    by: ActorKind.agent,
    actor: 'Agent',
  ).apply(
    taskId: task.id,
    op: 'units.tag.import',
    edit: (fresh) => TaskEdit(
      task: fresh.copyWith(units: parsed.units),
      before: {'unitCount': fresh.units?.length ?? 0},
      after: {'unitCount': parsed.units.length},
    ),
  );
  if (done == null) {
    err.writeln('这条任务在应用标签的过程中被删掉了：${task.id}');
    return exitNotFound;
  }
  clearAnalysisState(dataDir, task.id);
  emitJson(taskToJson(done), out: out);
  return 0;
}

/// 方案落在任务目录旁边：`<dataDir>/plans/<taskId>.json`。
///
/// 不塞进任务 JSON：那份是 GUI 也在写的，两边同时改一个文件的不同部分
/// 只会把冲突变复杂。方案是 Agent 这条路独有的产物，单独放。
void _writePlans(Directory dataDir, String taskId, String raw) {
  final file = File(p.join(dataDir.path, 'plans', '$taskId.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(raw);
}

/// 读回已提交的方案；没有就返回 null
String? readSubmittedPlans(Directory dataDir, String taskId) {
  final file = File(p.join(dataDir.path, 'plans', '$taskId.json'));
  return file.existsSync() ? file.readAsStringSync() : null;
}

Future<String> _readStdin() async =>
    await stdin.transform(utf8.decoder).join();


/// 委派是首选路径，不是必经之路（见 `delegate.dart`）：界面确实停在这条
/// 任务上就请它代办——**人不用挪开，还能眼看着方案落到时间线上**；
/// 界面没跟上（不在这条任务上、或者接了单没应）就自己直写，零等待或
/// 秒级兜底，绝不因为可视化掉线就卡住。
Future<int> _applyPlansViaUi({
  required Directory dataDir,
  required RenewTask task,
  required String? file,
  required Future<String> Function()? readStdin,
  required StringSink sink,
  required StringSink? out,
  MiaoaContentService? contentService,
  CandidateProbe? candidateProbe,
  Future<FrameCheck> Function(int id)? frameCheckOf,
}) async {
  final String raw;
  try {
    raw = file == null
        ? await (readStdin ?? _readStdin)()
        : File(file).readAsStringSync();
  } catch (e) {
    sink.writeln('读不到方案文件：$e');
    return exitBadUsage;
  }

  // **素材在这一头收，不管最后走哪条路**：探时长要 ffprobe、看画面要
  // AI 凭据，这些都在命令行这边；委派给界面时投影给人看，自己直写时
  // 直接用来落盘——同一份准备工作，不能因为走委派就漏、也不能因为
  // 秒级兜底赶时间就重算一遍（gatherPickedMaterials 本身可能要跑
  // 几十次 AI 调用，放进 2 秒超时的窗口里只会让委派形同虚设）。
  //
  // 一度只把 raw 递过去就完事——于是委派这条路上取段全失效（用不到素材
  // 时长）、画面自查一次不跑，出现了最难发现的组合：**人在旁边看着的时候，
  // 检查反而不做**，而那正是他最信任的一次。
  //
  // validation 拿不到有效结果时**不能悄悄当成空方案**——那会让秒级兜底
  // 直写一份「什么都没改」的方案，报 ok:true，而真实原因是解析失败
  PlanValidation validation =
      const PlanValidation(errors: ['方案内容解析失败']);
  List<PickedMaterial> picked = task.pickedMaterials;
  try {
    validation = parsePlans(jsonDecode(raw), task);
    if (validation.ok) {
      picked = await gatherPickedMaterials(
        replacements:
            projectPlansToReplacements(validation.plans, task.units ?? const []),
        task: task,
        dataDir: dataDir,
        contentService: contentService,
        candidateProbe: candidateProbe,
        frameCheckOf: frameCheckOf,
      );
    }
  } catch (e) {
    // 方案本身有问题的话，界面那头会给出准确的报错——这里不抢话，
    // 委派那条路继续把 raw 递过去；走到自己直写那条路时，上面那个
    // 占位的 validation 会让它老实拒绝，而不是当空方案悄悄写过去
    stderr.writeln('提交前没能把素材收齐（$e）——'
        '取段和画面自查这一轮会缺，方案本身照常提交');
  }

  return delegateOrDoItYourself<int>(
    dataDir: dataDir,
    taskId: task.id,
    viaUi: () async {
      sink.writeln('这个任务的页面正开着，已请界面代为提交——人能看着方案落进去…');
      final id = writeAgentRequest(
        dataDir: dataDir,
        taskId: task.id,
        kind: UiAction.plansApply.wire,
        payload: {
          'raw': raw,
          'pickedMaterials': [for (final m in picked) m.toJson()],
        },
      );
      final result =
          await waitForAgentRequest(dataDir: dataDir, taskId: task.id, id: id);
      if (result == null) return null; // 没应，交给自己直写
      if (!result.ok) {
        // 这是界面**真的答复了**、只是没做成——不是「没应」，不兜底，
        // 原样把拒绝理由带回去
        sink.writeln('没提交成功：${result.message}');
        return exitFailed;
      }
      emitJson({
        'ok': true,
        'via': 'ui',
        'message': result.message,
        ...result.payload,
        // **和直写给出同一份报告**。不给的话就出现了最别扭的一种缺口：
        // 检查跑了、界面上那条橙色警告也报了，**只有 Agent 拿不到**——
        // 而委派正是人在旁边看着时走的那条路，人扭头问「它刚才说啥了」，
        // Agent 答不上来
        ...planApplyReport(
            plans: validation.plans,
            picked: picked,
            task: task,
            shortSlots: shortSlotsOf(task)),
      }, out: out);
      return 0;
    },
    myself: () async {
      if (!validation.ok) {
        for (final problem in validation.errors) {
          sink.writeln('· $problem');
        }
        return exitBadUsage;
      }
      sink.writeln('界面不在这条任务上（或没跟上），直接自己提交…');
      return _commitPlans(
        dataDir: dataDir,
        task: task,
        repository: FileTaskRepository(dataDir),
        raw: raw,
        plans: validation.plans,
        picked: picked,
        sink: sink,
        out: out,
      );
    },
  );
}

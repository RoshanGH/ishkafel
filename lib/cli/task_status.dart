import '../core/models/renew_task.dart';
import '../core/script/shot_coverage.dart';
import '../core/script/script_doc.dart';

/// 一条任务**干到哪了、下一步该敲什么**。
///
/// 为什么要有这个：活儿被打断是常态——人按了停、命令超时、app 关掉了、
/// 隔了一天回来接着做。重新接手的那个 Agent 手里什么上下文都没有，
/// 它只能一条条 `script show` 去翻，然后**照着流程从头再走一遍**：
/// 重新打标（十几分钟、几十次识图）、重新配音（一轮 TTS）——全是白花的。
///
/// 而且**人在打断期间多半动过手**（自己挑了几个镜头、改了断句、换了音色），
/// 接手的 Agent 得看得出来这些，别把人的活儿覆盖掉。
///
/// 所以这里给的是**事实 + 下一步**，不是一堆原始字段：
/// 每一步做完了没有、做了多少、还差谁，以及**照着敲就能接着走的那条命令**。
class TaskStatus {
  final RenewTask task;

  /// 一句话说清干到哪了
  final String stage;

  /// 每一步的完成情况（有序，照流程排）
  final List<({String step, String state, bool done})> steps;

  /// 下一步照着敲这条
  final String? next;

  /// 挡着导出的问题（有就先解决它）
  final List<String> blocking;

  const TaskStatus({
    required this.task,
    required this.stage,
    required this.steps,
    required this.next,
    required this.blocking,
  });

  Map<String, dynamic> toJson() => {
        'seq': ?task.seq,
        'id': task.id,
        'name': task.name,
        'kind': task.script != null ? 'script' : 'replace',
        'stage': stage,
        'steps': [
          for (final s in steps)
            {'step': s.step, 'state': s.state, 'done': s.done},
        ],
        'next': ?next,
        if (blocking.isNotEmpty) 'blocking': blocking,
        // **人可能在你不在的时候动过手**：拿这个时间和你自己上次操作的时间
        // 比一比，对不上就先看一眼他改了什么，别直接覆盖
        'updatedAt': task.updatedAt.toIso8601String(),
        'exportedTimes': task.exports.length,
      };
}

/// 脚本成片这条线走到哪了。
TaskStatus scriptStatus(RenewTask task, ScriptDoc doc) {
  final voiced =
      doc.lines.where((l) => l.type == ScriptLineType.voiced).toList();
  final withVoice = voiced
      .where((l) => doc.voiceStateOf(l) == LineVoiceState.fresh)
      .length;
  final withShots = doc.lines.where((l) => l.shots.isNotEmpty).length;
  final needShots = doc.lines.where((l) => l.shots.isEmpty).toList();

  var refShots = 0;
  var refTagged = 0;
  for (final line in doc.lines) {
    final ref = line.reference;
    if (ref == null) continue;
    for (final (start, _) in ref.segments) {
      refShots++;
      if ((ref.metaAt(start)?.description ?? '').isNotEmpty) refTagged++;
    }
  }

  final steps = <({String step, String state, bool done})>[
    (
      step: '台词',
      state: doc.lines.isEmpty ? '还没有' : '${doc.lines.length} 句',
      done: doc.lines.isNotEmpty
    ),
    if (refShots > 0)
      (
        step: '参考镜打标',
        state: '$refTagged/$refShots 镜',
        done: refTagged >= refShots
      ),
    (
      step: '本片音色',
      state: doc.defaultVoiceId ?? '还没定',
      done: doc.defaultVoiceId != null
    ),
    (
      step: '配音',
      state: '$withVoice/${voiced.length} 句',
      done: voiced.isNotEmpty && withVoice >= voiced.length
    ),
    (
      step: '挑镜头',
      state: '$withShots/${doc.lines.length} 行',
      done: needShots.isEmpty && doc.lines.isNotEmpty
    ),
    (
      step: '配乐',
      state: doc.bgmSegments.isEmpty ? '没铺' : '${doc.bgmSegments.length} 段',
      done: doc.bgmSegments.isNotEmpty
    ),
    (
      step: '导出',
      state: task.exports.isEmpty ? '还没导过' : '导过 ${task.exports.length} 次',
      done: task.exports.isNotEmpty
    ),
  ];

  // 下一步：**照流程找第一件没做完的事**，给出能直接敲的命令
  final id = task.id;
  String? next;
  String stage;
  if (doc.lines.isEmpty) {
    stage = '空任务，还没有台词';
    next = 'ishkafel script extract $id <参考片>（有参考片）'
        '，或 ishkafel script apply lines $id --file l.json（手写）';
  } else if (refShots > 0 && refTagged < refShots) {
    // 找第一句没打完标的
    var line = 1;
    for (var i = 0; i < doc.lines.length; i++) {
      final ref = doc.lines[i].reference;
      if (ref == null) continue;
      final undone = ref.segments
          .any((seg) => (ref.metaAt(seg.$1)?.description ?? '').isEmpty);
      if (undone) {
        line = i + 1;
        break;
      }
    }
    stage = '参考镜打标还差 ${refShots - refTagged} 镜';
    next = 'ishkafel script tag-ref $id --line $line';
  } else if (doc.defaultVoiceId == null) {
    stage = '还没定本片音色';
    next = 'ishkafel voices 看有哪些，再 ishkafel script apply baseline $id --file b.json';
  } else if (withVoice < voiced.length) {
    stage = '配音还差 ${voiced.length - withVoice} 句';
    next = 'ishkafel script voice $id';
  } else if (needShots.isNotEmpty) {
    final line = doc.lines.indexOf(needShots.first) + 1;
    stage = '还有 ${needShots.length} 行没挑镜头';
    next = 'ishkafel script shots $id --line $line';
  } else if (task.exports.isEmpty) {
    stage = '都齐了，可以导出';
    next = 'ishkafel script export $id';
  } else {
    stage = '已经导出过 ${task.exports.length} 次';
    next = null;
  }

  return TaskStatus(
    task: task,
    stage: stage,
    steps: steps,
    next: next,
    blocking: _blockingOf(doc),
  );
}

/// 替换裂变这条线走到哪了。
TaskStatus renewStatus(RenewTask task) {
  final units = task.units ?? const [];
  final planned = task.replacementsByUid.length;
  final steps = <({String step, String state, bool done})>[
    (
      step: '分析切分',
      state: units.isEmpty ? '还没分析' : '${units.length} 个台词语义单元',
      done: units.isNotEmpty
    ),
    (
      step: '替换方案',
      state: planned == 0 ? '还没提交' : '$planned 条',
      done: planned > 0
    ),
    (
      step: '导出',
      state: task.exports.isEmpty ? '还没导过' : '导过 ${task.exports.length} 次',
      done: task.exports.isNotEmpty
    ),
  ];
  String stage;
  String? next;
  if (units.isEmpty) {
    stage = '还没分析';
    next = 'ishkafel analyze ${task.id}';
  } else if (planned == 0) {
    stage = '分析好了，还没挑素材';
    next = 'ishkafel candidates ${task.id} --unit 0';
  } else if (task.exports.isEmpty) {
    stage = '有 $planned 条方案，还没导出';
    next = 'ishkafel export ${task.id}';
  } else {
    stage = '已经导出过 ${task.exports.length} 次';
    next = null;
  }
  return TaskStatus(
      task: task, stage: stage, steps: steps, next: next, blocking: const []);
}

TaskStatus statusOf(RenewTask task) {
  final doc = task.script;
  return doc != null ? scriptStatus(task, doc) : renewStatus(task);
}


/// 挡着导出的那几条（和 `script show --json` 里的 blocking 同源，
/// 这里只取人话那一句）
List<String> _blockingOf(ScriptDoc doc) => [
      for (final g in shotCoverageGaps(doc))
        '第 ${g.lineIndex + 1} 行第 ${g.shotIndex + 1} 镜的画面铺不满这一镜的时长',
      for (var i = 0; i < doc.lines.length; i++)
        if (doc.lines[i].type == ScriptLineType.voiced &&
            doc.lines[i].voiceover != null &&
            doc.lines[i].voiceover!.words.isEmpty)
          '第 ${i + 1} 行的配音没有逐字时间，断不了句',
    ];

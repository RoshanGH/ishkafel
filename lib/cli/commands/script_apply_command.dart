import 'dart:convert';
import 'dart:io';
import '../frame_check_wiring.dart';
import '../../core/script/shot_frame_check.dart';

import '../../core/audio/bgm_plan.dart';

import '../../core/script/bgm_rail.dart';
import '../../core/script/script_cover.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/sound_mix.dart';
import '../../core/script/shot_allocation.dart';
import '../../core/script/word_shot_insert.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_media.dart';
import '../../core/storage/task_seq.dart';
import '../agent_lock_holder.dart';
import '../cli_output.dart';
import '../lock_yield.dart';
import '../gui_lock_guidance.dart';
import '../agent_stage.dart';
import '../script_apply.dart';

/// Agent 能提交的所有改动类型。**新增一类就要同步写进手册**——
/// 有架构测试盯着（见 test/architecture/agent_parity_test.dart）：
/// Agent 看不到的能力等于不存在，这个坑已经踩过三次
const List<String> scriptApplyKinds = [
  'shots', 'subtitles', 'alloc', 'bgm',
  'lines', 'shot-edit', 'screen-text',
  'baseline', 'line-voice', 'mix', 'word-shots',
];

/// `ishkafel script apply <shots|subtitles|alloc|bgm> <task> --file <json>`
///
/// 顺序不许变：**读文件 → 校验 → 拿锁 → 重读任务 → 再校验一次 → 写入 →
/// 留痕 → 放锁**。第二次校验不是多余的：拿锁期间人可能在界面里改过这个
/// 任务，第一次校验时成立的前提可能已经不成立了。
///
/// 每一步都上报在场状态（见 [AgentPresence]），界面据此跟着走——它看哪一行，
/// 界面就把哪一行摆到眼前。
Future<int> runScriptApplyCommand({
  required List<String> rest,
  required Directory dataDir,
  String? file,
  String? holder,

  /// 可视模式：把软件拉起来、每步等界面展示完（见 AgentStage）
  bool? visual,

  /// 测试注入：怎么看一条素材的画面（烧字 + 产品露出品牌）。
  /// 不传就用真的（抽本地素材的头中尾三帧）
  ShotFrameCheck? frameCheckOf,
  Future<String> Function()? readStdin,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  const supported = scriptApplyKinds;
  if (rest.length < 2) {
    sink.writeln('用法：ishkafel script apply <${supported.join('|')}> '
        '<任务 id> --file <结果.json>');
    return exitBadUsage;
  }
  final what = rest[0];
  if (!supported.contains(what)) {
    sink.writeln('认不出「$what」。可用：${supported.join(' / ')}');
    return exitBadUsage;
  }
  final id = rest[1];

  final Map<String, dynamic> payload;
  try {
    final raw = file != null
        ? File(file).readAsStringSync()
        : await (readStdin ?? _readStdin)();
    payload = jsonDecode(raw) as Map<String, dynamic>;
  } catch (e) {
    sink.writeln('读不懂提交的内容（要求是一个 JSON 对象）：$e');
    return exitBadUsage;
  }

  final repository = FileTaskRepository(dataDir);
  final task = await resolveTaskRef(repository, id);
  if (task == null) {
    sink.writeln('没有这个任务：$id');
    return exitNotFound;
  }
  if (task.script == null) {
    sink.writeln('「${task.name}」不是脚本成片任务');
    return exitBadUsage;
  }

  // 先在锁外面校验一遍：不合格就别去打扰正在用界面的人
  final first = _validate(what, task.script!, payload);
  if (first.isNotEmpty) {
    _reject(first, sink);
    return exitBadUsage;
  }

  final lock = TaskLockFile(dataDir: dataDir, taskId: task.id);
  if (!await acquireYieldingFromUi(
      lock: lock,
      holder: holder ?? agentLockHolder,
      dataDir: dataDir,
      taskId: task.id)) {
    final current = lock.read();
    sink.writeln(guiLockGuidance(
        holder: current?.holder, taskId: task.id));
    return exitLocked;
  }
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder ?? agentLockHolder,
  );
  // 可视模式下这一句会把软件拉起来、落到这个任务、等界面真的展示完
  await stage.begin(_actionOf(what, payload), focus: _focusOf(what, payload));
  if (!stage.visual) {
    // 静默模式也要写在场状态：万一人正开着界面，至少知道有东西在动它
    writeAgentPresence(
      dataDir: dataDir,
      taskId: task.id,
      presence: AgentPresence(
        holder: holder ?? agentLockHolder,
        at: DateTime.now(),
        action: _actionOf(what, payload),
        focus: _focusOf(what, payload),
      ),
    );
  }

  try {
    // 拿锁期间人可能改过：重读一遍再校验，别拿旧前提写新数据
    final fresh = await repository.findById(task.id);
    final doc = fresh?.script;
    if (doc == null) {
      sink.writeln('任务在写入前被删了或不再是脚本任务');
      return exitNotFound;
    }
    final second = _validate(what, doc, payload);
    if (second.isNotEmpty) {
      sink.writeln('（拿到锁之后重新核对，这些不再成立——'
          '多半是有人在界面里改过）');
      _reject(second, sink);
      return exitBadUsage;
    }

    final next = await _apply(what, doc, payload,
        dataDir: dataDir, taskId: task.id, frameCheckOf: frameCheckOf);
    // 封面 = 成片第一帧。Agent 挑完镜头，列表页上这条片子就该有画面了，
    // 不然它和一个空任务长得一模一样
    final cover = await ensureScriptCover(
      doc: next,
      dataDir: dataDir,
      taskId: task.id,
      localPathOf: (id) {
        return TaskMedia(dataDir: dataDir, taskId: task.id).localMaterial(id);
      },
    );
    await repository.save(fresh!.copyWith(
      script: next,
      coverPath: cover ?? fresh.coverPath,
    ));
    // **有素材没看成画面就要点名**，不能只往日志里写一行 warn。
    //
    // 素材还没落到本地时画面自查整批跳过，于是 framesSeen 全是 null。
    // 手册反复讲「null 是没看成、不是没问题」，却没给过补救的路——
    // 验收 Agent 只能自己摸出「先 peek 把素材拉下来，再原样重提一遍」，
    // 而正是那一轮才查出有条素材底部烧着别的片子的台词：照第一轮直接导出，
    // 交付的就是两层字幕打架的废片
    final unchecked = what == 'shots' ? _uncheckedMaterialIds(next) : const <int>[];
    emitJson({
      'ok': true,
      'what': what,
      'taskId': task.id,
      'applied': _countOf(what, payload),
      // 说清改了什么，别让调用方靠 applied 的数字去猜
      'changed': _changedOf(what, payload),
      if (unchecked.isNotEmpty) ...{
        'uncheckedMaterials': unchecked,
        'warning': '这 ${unchecked.length} 条素材的画面**没看成**'
            '（多半是还没落到本地）——不是「没问题」，是「不知道有没有问题」。'
            '素材上要是烧着别的片子的字，我们再烧一行台词就是两层字打架，'
            '整条片子废掉。',
        'next': 'ishkafel script peek <任务> --materials '
            '${unchecked.join(',')} 把它们拉到本地，'
            '然后把刚才这份提交**原样再提一次**，这次才会真的看图',
      },
    }, out: out);
    return 0;
  } finally {
    stage.end();
    lock.release(holder ?? agentLockHolder);
  }
}

String? _str(Object? v) => v is String ? v : null;
int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
double? _dbl(Object? v) => v is num ? v.toDouble() : null;

List<WordShotPick> _wordShots(Map<String, dynamic> payload) {
  final raw = payload['picks'];
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map &&
          e['lineIndex'] is int &&
          e['startWord'] is int &&
          e['endWord'] is int &&
          e['materialId'] is int)
        (
          lineIndex: e['lineIndex'] as int,
          startWord: e['startWord'] as int,
          endWord: e['endWord'] as int,
          materialId: e['materialId'] as int,
        ),
  ];
}

List<LineVoiceEdit> _lineVoices(Map<String, dynamic> payload) {
  final raw = payload['lines'];
  if (raw is! List) return const [];
  return [
    for (final e in raw)
      if (e is Map && e['lineIndex'] is int)
        (
          lineIndex: e['lineIndex'] as int,
          voiceId: _str(e['voiceId']),
          speechRate: _int(e['speechRate']),
        ),
  ];
}

/// 混音台是**增量改**：只给要动的那几项，其余保持现状。
/// 全量覆盖的话，Agent 想只调配乐就得先把另外两条读出来再原样写回去，
/// 中间人改了就被它覆盖掉了
SoundMix _mixOf(ScriptDoc doc, Map<String, dynamic> payload) {
  final m = payload['sound'] is Map
      ? Map<String, dynamic>.from(payload['sound'] as Map)
      : payload;
  return doc.mix.copyWith(
    source: _dbl(m['source']),
    voice: _dbl(m['voice']),
    bgm: _dbl(m['bgm']),
    sourceMuted: m['sourceMuted'] is bool ? m['sourceMuted'] as bool : null,
    voiceMuted: m['voiceMuted'] is bool ? m['voiceMuted'] as bool : null,
    bgmMuted: m['bgmMuted'] is bool ? m['bgmMuted'] as bool : null,
    duckSourceUnderVoice: m['duckSourceUnderVoice'] is bool
        ? m['duckSourceUnderVoice'] as bool
        : null,
    duckedSourceVolume: _dbl(m['duckedSourceVolume']),
  );
}

Future<String> _readStdin() async =>
    await stdin.transform(utf8.decoder).join();

void _reject(List<ApplyIssue> issues, StringSink sink) {
  sink.writeln('这一批没有落盘（整批拒绝，下面是全部问题）：');
  for (final i in issues) {
    sink.writeln('· ${i.message}');
  }
}

List<ApplyIssue> _validate(
    String what, ScriptDoc doc, Map<String, dynamic> payload) {
  switch (what) {
    case 'shots':
      return validateShotsSubmission(
        doc: doc,
        picks: _picks(payload),
        offered: _offeredShots(payload),
      );
    case 'subtitles':
      return validateSubtitleSubmission(
          doc: doc, submissions: _subtitles(payload));
    case 'alloc':
      return validateAllocSubmission(doc: doc, submissions: _allocs(payload));
    case 'bgm':
      return validateBgmSubmission(
        doc: doc,
        submissions: _bgms(payload),
        offered: _offeredBgm(payload),
      );
    case 'lines':
      return validateLineEdits(doc: doc, edits: _lineEdits(payload));
    case 'shot-edit':
      return validateShotEdits(doc: doc, edits: _shotEdits(payload));
    case 'screen-text':
      return validateScreenTexts(doc: doc, edits: _screenTexts(payload));
    case 'baseline':
      return validateBaselineSubmission(
          doc: doc,
          voiceId: _str(payload['voiceId']),
          speechRate: _int(payload['speechRate']));
    case 'line-voice':
      return validateLineVoiceSubmission(doc: doc, edits: _lineVoices(payload));
    case 'mix':
      return validateMixSubmission(doc: doc, mix: _mixOf(doc, payload));
    case 'word-shots':
      return validateWordShotSubmission(
          doc: doc,
          picks: _wordShots(payload),
          offered: _offeredMaterials(payload).keys.toSet());
    default:
      return const [];
  }
}

Future<ScriptDoc> _apply(
  String what,
  ScriptDoc doc,
  Map<String, dynamic> payload, {
  required Directory dataDir,
  required String taskId,
  ShotFrameCheck? frameCheckOf,
}) async {
  var next = doc;
  switch (what) {
    case 'shots':
      final offered = _offeredMaterials(payload);
      // **画面自查**：素材上烧着别家的字，我们再给台词烧一行，就是两层字
      // 叠在一起；画面里露的是竞品，台词说的和画面里摆的对不上——两样都
      // 只有看图才发现得了，而且都会毁掉整片。替换裂变那边在 apply 时查，
      // 这条线一开始整条缺席（见 shot_frame_check.dart）
      final checker =
          frameCheckOf ?? defaultShotFrameCheck(dataDir: dataDir, taskId: taskId);
      for (final pick in _picks(payload)) {
        final line = next.lines[pick.lineIndex];
        final shots = checker == null
            ? [for (final id in pick.materialIds) offered[id]!]
            : await checkedShots(
                shots: [for (final id in pick.materialIds) offered[id]!],
                check: (s) => checker(s.materialId, s.durationMs),
              );
        // 落盘时必须跟着分时长，否则 allocMs 为 null，这一行进不了预览
        final root = ShotAllocation.rootMsOf(line.withShots(shots));
        next = next.setShotsById(
            line.id,
            root == null
                ? shots
                : ShotAllocation.fillBySlowdown(
                    reallocShots(line, shots), root));
      }
    case 'subtitles':
      for (final sub in _subtitles(payload)) {
        final line = next.lines[sub.lineIndex];
        next = next.setScreensById(line.id, [
          const SubtitleScreen(startWord: 0),
          for (final c in sub.cuts) SubtitleScreen(startWord: c),
        ]);
      }
    case 'alloc':
      for (final sub in _allocs(payload)) {
        final line = next.lines[sub.lineIndex];
        next = next.setShotsById(line.id, [
          for (var j = 0; j < line.shots.length; j++)
            line.shots[j].copyWith(allocMs: sub.allocMs[j]),
        ]);
      }
    case 'bgm':
      final offered = _offeredBgmMaterials(payload);
      var rail = bgmRail(next.bgmSegments, next.lines.length);
      for (final seg in _bgms(payload)) {
        rail = setRailRange(
            rail, seg.startLine, seg.endLine, offered[seg.materialId], seg.volume);
      }
      next = next.withBgmSegments(railToSegments(rail));
    case 'lines':
      // 倒着做：先删后面的，前面的下标才不会被搅乱
      final edits = [..._lineEdits(payload)]
        ..sort((a, b) => b.lineIndex.compareTo(a.lineIndex));
      for (final e in edits) {
        switch (e.op) {
          case 'set':
            next = next.updateText(e.lineIndex, e.text ?? '');
          case 'insert':
            next = next.insertAfter(e.lineIndex);
            if ((e.text ?? '').isNotEmpty) {
              next = next.updateText(e.lineIndex + 1, e.text!);
            }
          case 'remove':
            next = next.removeAt(e.lineIndex);
        }
      }
    case 'shot-edit':
      final edits = [..._shotEdits(payload)]
        ..sort((a, b) => b.shotIndex.compareTo(a.shotIndex));
      for (final e in edits) {
        final line = next.lines[e.lineIndex];
        final shots = [...line.shots];
        switch (e.op) {
          case 'remove':
            shots.removeAt(e.shotIndex);
          case 'trim':
            shots[e.shotIndex] = ShotAllocation.setTrimStart(
                shots[e.shotIndex], e.value!.round());
          case 'speed':
            shots[e.shotIndex] = ShotAllocation.setSpeed(
                shots[e.shotIndex], e.value!.toDouble());
          case 'volume':
            shots[e.shotIndex] =
                shots[e.shotIndex].withSourceVolume(e.value!.toDouble());
        }
        // 删了镜头就把剩下的重新分满这一行；其余编辑保持既有分配
        final root = ShotAllocation.rootMsOf(line);
        next = next.setShotsById(
            line.id,
            e.op == 'remove' && root != null && shots.isNotEmpty
                ? ShotAllocation.fillBySlowdown(
                    reallocShots(line, shots), root)
                : shots);
      }
    case 'baseline':
      final voiceId = _str(payload['voiceId']);
      final rate = _int(payload['speechRate']);
      // 「统一全片」= 设基调 + 清各行覆盖；只设基调则保留各行单独设过的。
      // 默认走统一——人说「全片换成云希」时，之前单独试过音色的那几行
      // 留在旧音色上就是错的
      final unify = payload['unify'] != false;
      if (voiceId != null) {
        next = unify ? next.unifyVoice(voiceId) : next.withDefaultVoiceId(voiceId);
      }
      if (rate != null) {
        next = unify
            ? next.unifySpeechRate(rate)
            : next.withDefaultSpeechRate(rate);
      }
      return next;
    case 'line-voice':
      for (final e in _lineVoices(payload)) {
        if (e.voiceId != null) next = next.setVoiceId(e.lineIndex, e.voiceId);
        if (e.speechRate != null) {
          next = next.setSpeechRate(e.lineIndex, e.speechRate!);
        }
      }
      return next;
    case 'word-shots':
      final offered = _offeredMaterials(payload);
      // 按字序插入而不是追加：Agent 也可能先划句尾再划句首，
      // 追加会让镜头顺序和台词顺序反过来
      for (final p in _wordShots(payload)) {
        final line = next.lines[p.lineIndex];
        final shot = offered[p.materialId]!
            .copyWith(startWord: p.startWord, endWord: p.endWord);
        final shots = [...line.shots];
        shots.insert(insertIndexForWords(shots, p.startWord), shot);
        next = next.setShotsById(line.id, reallocShots(line, shots));
      }
      return next;
    case 'mix':
      return next.withMix(_mixOf(next, payload));
    case 'screen-text':
      for (final e in _screenTexts(payload)) {
        final line = next.lines[e.lineIndex];
        next = next.setScreenTextById(line.id, e.screenIndex, e.text);
      }
  }
  return next;
}

// ——— 提交格式的解析。认不出的字段一律忽略，缺的由校验器点名 ———

List<ShotPick> _picks(Map<String, dynamic> payload) => [
      for (final p in (payload['picks'] as List? ?? const []))
        if (p is Map && p['lineIndex'] is int)
          (
            lineIndex: p['lineIndex'] as int,
            materialIds: [
              for (final id in (p['materialIds'] as List? ?? const []))
                if (id is int) id,
            ],
          ),
    ];

/// 候选：素材 id → 它能出多长成片。Agent 提交时要把这份一起带上，
/// 否则我们无从判断它选的东西存不存在、够不够铺
Map<int, int> _offeredShots(Map<String, dynamic> payload) => {
      for (final m in _offeredList(payload))
        if (m is Map && m['materialId'] is int)
          m['materialId'] as int: (m['availableMs'] as int?) ??
              (m['durationMs'] as int?) ??
              0,
    };

Map<int, LineShot> _offeredMaterials(Map<String, dynamic> payload) => {
      for (final m in _offeredList(payload))
        if (m is Map && m['materialId'] is int)
          m['materialId'] as int: LineShot(
            materialId: m['materialId'] as int,
            name: '${m['name'] ?? '素材'}',
            sceneDescription: '${m['sceneDescription'] ?? ''}',
            voiceover: '${m['voiceover'] ?? ''}',
            thumbnailUrl: m['thumbnailUrl'] as String?,
            fileKey: m['fileKey'] as String?,
            durationMs: m['durationMs'] as int?,
          ),
    };

List<SubtitleCuts> _subtitles(Map<String, dynamic> payload) => [
      for (final s in (payload['subtitles'] as List? ?? const []))
        if (s is Map && s['lineIndex'] is int)
          (
            lineIndex: s['lineIndex'] as int,
            cuts: [
              for (final c in (s['cuts'] as List? ?? const []))
                if (c is int) c,
            ],
          ),
    ];

List<AllocSubmission> _allocs(Map<String, dynamic> payload) => [
      for (final a in (payload['alloc'] as List? ?? const []))
        if (a is Map && a['lineIndex'] is int)
          (
            lineIndex: a['lineIndex'] as int,
            allocMs: [
              for (final v in (a['allocMs'] as List? ?? const []))
                if (v is int) v,
            ],
          ),
    ];

List<BgmSubmission> _bgms(Map<String, dynamic> payload) => [
      for (final b in (payload['bgm'] as List? ?? const []))
        if (b is Map && b['startLine'] is int && b['endLine'] is int)
          (
            startLine: b['startLine'] as int,
            endLine: b['endLine'] as int,
            materialId: b['materialId'] is int ? b['materialId'] as int : -1,
            volume: (b['volume'] as num?)?.toDouble() ?? 0.25,
          ),
    ];


/// 提交里那份「候选清单」。**两个名字都认**：手册的样例 JSON 写的是
/// `offered`，而这份代码原本只读 `candidates`——配乐那节又恰好只提
/// offered，于是 `apply bgm` 照手册写必错，报的还是「配乐 108 不在候选里」
/// （验收 Agent 两种形状都试了都拒，交付的成片全片没有配乐）。
List<dynamic> _offeredList(Map<String, dynamic> payload) {
  for (final key in const ['candidates', 'offered']) {
    final v = payload[key];
    if (v is List && v.isNotEmpty) return v;
  }
  return const [];
}

/// 配乐候选的 id 集合。测试要用，所以是公开的
Set<int> offeredBgmIds(Map<String, dynamic> payload) => _offeredBgm(payload);

/// 挑镜头候选的 id 集合。测试要用，所以是公开的
Set<int> offeredShotIds(Map<String, dynamic> payload) =>
    _offeredShots(payload).keys.toSet();

Set<int> _offeredBgm(Map<String, dynamic> payload) => {
      for (final m in _offeredList(payload))
        if (m is Map && m['materialId'] is int) m['materialId'] as int,
    };

Map<int, BgmMaterial> _offeredBgmMaterials(Map<String, dynamic> payload) => {
      for (final m in _offeredList(payload))
        if (m is Map && m['materialId'] is int)
          m['materialId'] as int: BgmMaterial(
            id: m['materialId'] as int,
            name: '${m['name'] ?? '配乐'}',
            durationMs: (m['durationMs'] as int?) ?? 0,
            previewUrl: m['previewUrl'] as String?,
          ),
    };

List<LineEdit> _lineEdits(Map<String, dynamic> payload) => [
      for (final e in (payload['lines'] as List? ?? const []))
        if (e is Map && e['lineIndex'] is int)
          (
            op: '${e['op'] ?? 'set'}',
            lineIndex: e['lineIndex'] as int,
            text: e['text'] as String?,
          ),
    ];

List<ShotEdit> _shotEdits(Map<String, dynamic> payload) => [
      for (final e in (payload['shots'] as List? ?? const []))
        if (e is Map && e['lineIndex'] is int && e['shotIndex'] is int)
          (
            lineIndex: e['lineIndex'] as int,
            shotIndex: e['shotIndex'] as int,
            op: '${e['op'] ?? ''}',
            value: e['value'] as num?,
          ),
    ];

List<ScreenText> _screenTexts(Map<String, dynamic> payload) => [
      for (final e in (payload['screens'] as List? ?? const []))
        if (e is Map && e['lineIndex'] is int && e['screenIndex'] is int)
          (
            lineIndex: e['lineIndex'] as int,
            screenIndex: e['screenIndex'] as int,
            text: e['text'] as String?,
          ),
    ];

/// 播报里的一句话。
///
/// 人在旁边看着 Agent 干活，读到的就是这一句。所以它得说清**对哪几行
/// 做了什么**——「正在铺配乐」等于没说，「正在给第 3~15 行铺配乐」
/// 才知道它动了哪儿。
///
/// 只播**人能理解的动作**：内部的重试、轮询、缓存命中不进来，
/// 那些只会把真正的动作淹掉。
String _actionOf(String what, Map<String, dynamic> payload) => switch (what) {
      'shots' => '正在给${_lineLabel(payload, 'picks')}挑镜头',
      'subtitles' => '正在给${_lineLabel(payload, 'subtitles')}断句',
      'alloc' => '正在调${_lineLabel(payload, 'alloc')}的镜头时长',
      'bgm' => '正在给${_bgmLabel(payload)}铺配乐',
      'lines' => '正在改${_lineLabel(payload, 'lines')}的台词',
      'shot-edit' => '正在调${_lineLabel(payload, 'shots')}的镜头',
      'screen-text' => '正在改${_lineLabel(payload, 'screens')}的字幕文字',
      'baseline' => '正在定本片的音色与语速',
      'line-voice' => '正在改${_lineLabel(payload, 'lines')}的音色/语速',
      'mix' => '正在调三条声音轨的音量',
      'word-shots' => '正在给${_wordShotLabel(payload)}配画面',
      _ => '正在操作',
    };

/// 配乐段覆盖到哪几行：「第 3~15 行」
String _bgmLabel(Map<String, dynamic> payload) {
  final segs = _bgms(payload);
  if (segs.isEmpty) return '整片';
  var from = segs.first.startLine;
  var to = segs.first.endLine;
  for (final s in segs) {
    if (s.startLine < from) from = s.startLine;
    if (s.endLine > to) to = s.endLine;
  }
  return from == to ? '第 ${from + 1} 行' : '第 ${from + 1}~${to + 1} 行';
}

/// 划词建镜播的是**划了哪几个字**，那才是人关心的
String _wordShotLabel(Map<String, dynamic> payload) {
  final picks = _wordShots(payload);
  if (picks.isEmpty) return '选中的字';
  final p = picks.first;
  final more = picks.length > 1 ? ' 等 ${picks.length} 处' : '';
  return '第 ${p.lineIndex + 1} 行的第 ${p.startWord + 1}~${p.endWord} 个字$more';
}

String _lineLabel(Map<String, dynamic> payload, String key) {
  final list = payload[key] as List? ?? const [];
  if (list.isEmpty) return '这个脚本';
  if (list.length > 1) return '${list.length} 句';
  final first = list.first;
  final i = first is Map && first['lineIndex'] is int
      ? first['lineIndex'] as int
      : 0;
  return '第 ${i + 1} 句';
}

/// 界面跟着它走：它动哪一行，就把哪一行摆到眼前
AgentFocus? _focusOf(String what, Map<String, dynamic> payload) {
  final key = switch (what) {
    'shots' => 'picks',
    'subtitles' => 'subtitles',
    'alloc' => 'alloc',
    'shot-edit' => 'shots',
    'screen-text' => 'screens',
    'lines' => 'lines',
    'line-voice' => 'lines',
    'word-shots' => 'picks',
    _ => null,
  };
  if (key == null) return null;
  final list = payload[key] as List? ?? const [];
  if (list.isEmpty) return null;
  final first = list.first;
  if (first is! Map || first['lineIndex'] is! int) return null;
  return AgentFocus(
    lineIndex: first['lineIndex'] as int,
    panel: switch (what) {
      'shots' => AgentPanel.shot,
      'subtitles' => AgentPanel.subtitle,
      'alloc' => AgentPanel.shot,
      'shot-edit' => AgentPanel.shot,
      'screen-text' => AgentPanel.subtitle,
      _ => AgentPanel.none,
    },
  );
}

/// 改了什么——人话，直接可以转给用户
String _changedOf(String what, Map<String, dynamic> payload) => switch (what) {
      'baseline' => '本片基调：'
          '${[
            if (_str(payload['voiceId']) case final v?) '音色 $v',
            if (_int(payload['speechRate']) case final r?) '语速 $r',
          ].join('、')}',
      'mix' => '三条声音轨的音量',
      'shots' => '给 ${_picks(payload).length} 行挑了镜头',
      'word-shots' => '划词建了 ${_wordShots(payload).length} 个镜头',
      'subtitles' => '给 ${_subtitles(payload).length} 行断了句',
      'alloc' => '调了 ${_allocs(payload).length} 行的镜头时长',
      'bgm' => '铺了 ${_bgms(payload).length} 段配乐',
      'lines' => '改了 ${_lineEdits(payload).length} 处台词',
      'line-voice' => '改了 ${_lineVoices(payload).length} 行的音色/语速',
      'shot-edit' => '调了 ${_shotEdits(payload).length} 处镜头',
      'screen-text' => '改了 ${_screenTexts(payload).length} 屏字幕',
      _ => what,
    };

int _countOf(String what, Map<String, dynamic> payload) => switch (what) {
      'shots' => _picks(payload).length,
      'subtitles' => _subtitles(payload).length,
      'alloc' => _allocs(payload).length,
      'bgm' => _bgms(payload).length,
      'lines' => _lineEdits(payload).length,
      'shot-edit' => _shotEdits(payload).length,
      'screen-text' => _screenTexts(payload).length,
      'line-voice' => _lineVoices(payload).length,
      'word-shots' => _wordShots(payload).length,
      // baseline 和 mix 改的是**整片一处设置**，没有「几条」可数。
      // 原来落到 _ => 0，返回 {"ok":true,"applied":0}——读起来像
      // 「一条都没落」，验收 Agent 又跑了一次 show 才敢确认真的写进去了
      'baseline' || 'mix' => 1,
      _ => 0,
    };


/// 挑进方案、但画面**没看成**的素材（去重）。
///
/// 「没看成」和「没问题」长得一模一样——两种情况 burnedText 都是空的。
/// 分不开的话，一条烧着别人台词的素材会一路混到成片里。
List<int> _uncheckedMaterialIds(ScriptDoc doc) {
  final ids = <int>{};
  for (final line in doc.lines) {
    for (final shot in line.shots) {
      if (shot.framesSeen == null || shot.framesSeen == 0) {
        ids.add(shot.materialId);
      }
    }
  }
  return ids.toList()..sort();
}

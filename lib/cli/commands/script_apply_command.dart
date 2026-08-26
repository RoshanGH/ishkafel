import 'dart:convert';
import 'dart:io';

import '../../core/audio/bgm_plan.dart';
import 'package:path/path.dart' as p;

import '../../core/script/bgm_rail.dart';
import '../../core/script/script_cover.dart';
import '../../core/script/script_doc.dart';
import '../../core/script/shot_allocation.dart';
import '../../core/storage/agent_presence.dart';
import '../../core/storage/file_task_repository.dart';
import '../../core/storage/task_lock.dart';
import '../../core/storage/task_seq.dart';
import '../cli_output.dart';
import '../agent_stage.dart';
import '../script_apply.dart';

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
  String holder = 'Agent',

  /// 可视模式：把软件拉起来、每步等界面展示完（见 AgentStage）
  bool? visual,
  Future<String> Function()? readStdin,
  StringSink? out,
  StringSink? err,
}) async {
  final sink = err ?? stderr;
  const supported = [
    'shots', 'subtitles', 'alloc', 'bgm',
    'lines', 'shot-edit', 'screen-text',
  ];
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
  if (!lock.acquire(holder)) {
    final current = lock.read();
    sink.writeln('${current?.holder ?? '别人'} 正在操作这个任务，写不进去。'
        '等它结束，或在 app 里强制接管');
    return exitLocked;
  }
  final stage = AgentStage(
    mode: AgentStageMode.from(visual: visual),
    dataDir: dataDir,
    taskId: task.id,
    holder: holder,
  );
  // 可视模式下这一句会把软件拉起来、落到这个任务、等界面真的展示完
  await stage.begin(_actionOf(what, payload), focus: _focusOf(what, payload));
  if (!stage.visual) {
    // 静默模式也要写在场状态：万一人正开着界面，至少知道有东西在动它
    writeAgentPresence(
      dataDir: dataDir,
      taskId: task.id,
      presence: AgentPresence(
        holder: holder,
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

    final next = _apply(what, doc, payload);
    // 封面 = 成片第一帧。Agent 挑完镜头，列表页上这条片子就该有画面了，
    // 不然它和一个空任务长得一模一样
    final cover = await ensureScriptCover(
      doc: next,
      dataDir: dataDir,
      taskId: task.id,
      localPathOf: (id) {
        final f = File(p.join(dataDir.path, 'material_cache', '$id.mp4'));
        return f.existsSync() ? f.path : null;
      },
    );
    await repository.save(fresh!.copyWith(
      script: next,
      coverPath: cover ?? fresh.coverPath,
    ));
    emitJson({
      'ok': true,
      'what': what,
      'taskId': task.id,
      'applied': _countOf(what, payload),
    }, out: out);
    return 0;
  } finally {
    stage.end();
    lock.release(holder);
  }
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
    default:
      return const [];
  }
}

ScriptDoc _apply(String what, ScriptDoc doc, Map<String, dynamic> payload) {
  var next = doc;
  switch (what) {
    case 'shots':
      final offered = _offeredMaterials(payload);
      for (final pick in _picks(payload)) {
        final line = next.lines[pick.lineIndex];
        final shots = [
          for (final id in pick.materialIds) offered[id]!,
        ];
        // 落盘时必须跟着分时长，否则 allocMs 为 null，这一行进不了预览
        final root = ShotAllocation.rootMsOf(line.withShots(shots));
        next = next.setShotsById(
            line.id,
            root == null
                ? shots
                : ShotAllocation.fillBySlowdown(
                    ShotAllocation.distribute(shots, root), root));
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
                    ShotAllocation.distribute(shots, root), root)
                : shots);
      }
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
      for (final m in (payload['candidates'] as List? ?? const []))
        if (m is Map && m['materialId'] is int)
          m['materialId'] as int: (m['availableMs'] as int?) ??
              (m['durationMs'] as int?) ??
              0,
    };

Map<int, LineShot> _offeredMaterials(Map<String, dynamic> payload) => {
      for (final m in (payload['candidates'] as List? ?? const []))
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

Set<int> _offeredBgm(Map<String, dynamic> payload) => {
      for (final m in (payload['candidates'] as List? ?? const []))
        if (m is Map && m['materialId'] is int) m['materialId'] as int,
    };

Map<int, BgmMaterial> _offeredBgmMaterials(Map<String, dynamic> payload) => {
      for (final m in (payload['candidates'] as List? ?? const []))
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

String _actionOf(String what, Map<String, dynamic> payload) => switch (what) {
      'shots' => '正在给${_lineLabel(payload, 'picks')}挑镜头',
      'subtitles' => '正在给${_lineLabel(payload, 'subtitles')}断句',
      'alloc' => '正在调${_lineLabel(payload, 'alloc')}的镜头时长',
      'bgm' => '正在铺配乐',
      'lines' => '正在改台词',
      'shot-edit' => '正在调${_lineLabel(payload, 'shots')}的镜头',
      'screen-text' => '正在改${_lineLabel(payload, 'screens')}的字幕文字',
      _ => '正在操作',
    };

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

int _countOf(String what, Map<String, dynamic> payload) => switch (what) {
      'shots' => _picks(payload).length,
      'subtitles' => _subtitles(payload).length,
      'alloc' => _allocs(payload).length,
      'bgm' => _bgms(payload).length,
      'lines' => _lineEdits(payload).length,
      'shot-edit' => _shotEdits(payload).length,
      'screen-text' => _screenTexts(payload).length,
      _ => 0,
    };

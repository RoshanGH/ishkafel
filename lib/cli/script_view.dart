import '../core/models/renew_task.dart';
import '../core/script/script_doc.dart';
import '../core/script/shot_allocation.dart';
import '../core/script/shot_coverage.dart';

/// 脚本成片任务 → JSON。
///
/// 这是 Agent 干活前唯一的事实来源：它看不到界面，只能从这里知道有几句词、
/// 每句配了什么镜头、还差什么。**只做投影，不含判断**——「这个镜头挑得好
/// 不好」是 Agent 的事，软件只负责把事实摆全（spec 第一节）。
///
/// 三个字段是给它做判断用的，缺一个它就只能瞎猜：
/// - `availableMs`：这条素材从取段点起、按当前倍速还能出多长成片
/// - `shortfallMs`：这一行还差多少没分出去（正数 = 画面没铺满）
/// - `blocking`：会**拦下预览与导出**的问题。提交完必须自查这一项，
///   不能等人打开界面才发现
Map<String, dynamic> scriptTaskJson(RenewTask task) {
  final doc = task.script;
  if (doc == null) {
    throw ArgumentError('「${task.name}」不是脚本成片任务（它没有脚本）');
  }
  final gaps = shotCoverageGaps(doc);
  var totalMs = 0;
  for (final line in doc.lines) {
    totalMs += _lineSpanMs(line);
  }
  return {
    'id': task.id,
    if (task.seq != null) 'seq': task.seq,
    'name': task.name,
    'kind': 'script',
    if (doc.refVideoPath != null) 'refVideo': doc.refVideoPath,
    'sourceVolume': doc.sourceVolume,
    'totalMs': totalMs,
    'lines': [
      for (var i = 0; i < doc.lines.length; i++) _lineJson(doc, i),
    ],
    'bgm': [
      for (final seg in doc.bgmSegments)
        {
          'startLine': seg.startLine,
          'endLine': seg.endLine,
          'materialId': seg.material.id,
          'name': seg.material.name,
          'volume': seg.volume,
        },
    ],
    'blocking': [
      for (final g in gaps)
        {
          'lineIndex': g.lineIndex,
          'shotIndex': g.shotIndex,
          'kind': 'shot-too-short',
          'message': '第 ${g.lineIndex + 1} 行第 ${g.shotIndex + 1} 镜的画面只有 '
              '${_sec(g.usableMs)} 秒，铺不满 ${_sec(g.allocMs)} 秒',
        },
    ],
    'exports': [
      for (final e in task.exports)
        {
          'at': e.at.toIso8601String(),
          'dir': e.outputDir,
          'total': e.total,
          'succeeded': e.succeeded,
        },
    ],
  };
}

/// 单行详情。`script show <task> --line <i>` 用
Map<String, dynamic> scriptLineJson(ScriptDoc doc, int index) {
  if (index < 0 || index >= doc.lines.length) {
    throw ArgumentError('第 ${index + 1} 行不存在（脚本共 ${doc.lines.length} 行）');
  }
  return _lineJson(doc, index);
}

Map<String, dynamic> _lineJson(ScriptDoc doc, int i) {
  final line = doc.lines[i];
  final vo = line.voiceover;
  final root = ShotAllocation.rootMsOf(line);
  final style = line.subtitleOverride ?? doc.subtitle;
  final ref = line.reference;
  return {
    'index': i,
    'id': line.id,
    'type': line.type == ScriptLineType.voiced ? 'voiced' : 'visual',
    'text': line.text,
    if (line.tags.isNotEmpty) 'tags': line.tags,
    if (root != null) 'rootMs': root,
    if (vo != null)
      'voice': {
        'state': line.voiceState.name,
        if (vo.voiceId.isNotEmpty) 'voiceId': vo.voiceId,
        'durationMs': vo.durationMs,
        'speechRate': vo.speechRate,
        // 没有逐字时间就不能外包断句——让调用方看得见，别让它算了半天才发现
        'hasWordTimings': vo.words.isNotEmpty,
        if (line.voiceDefectText != null) 'defect': line.voiceDefectText,
      },
    'shots': [
      for (var j = 0; j < line.shots.length; j++) _shotJson(line.shots[j], j),
    ],
    if (root != null)
      'shortfallMs': ShotAllocation.shortfallMs(line.shots, root),
    if (ref != null) 'reference': _referenceJson(ref),
    'subtitle': {
      'manual': line.subtitleScreens != null,
      'maxCharsPerScreen': style.maxCharsPerScreen,
      'screens': [
        for (final s
            in line.subtitleScreensAt(maxChars: style.maxCharsPerScreen))
          {'startMs': s.startMs, 'endMs': s.endMs, 'text': s.text},
      ],
    },
  };
}

Map<String, dynamic> _shotJson(LineShot shot, int index) => {
      'index': index,
      'materialId': shot.materialId,
      'name': shot.name,
      if (shot.sceneDescription.isNotEmpty)
        'sceneDescription': shot.sceneDescription,
      if (shot.voiceover.isNotEmpty) 'voiceover': shot.voiceover,
      if (shot.allocMs != null) 'allocMs': shot.allocMs,
      'trimStartMs': shot.trimStartMs,
      'speed': shot.speed,
      if (shot.durationMs != null) 'durationMs': shot.durationMs,
      // 还能出多长成片：挑镜头与分时长都靠它
      if (shot.durationMs != null) 'availableMs': shot.availableMs,
      if (shot.localSource != null) 'localSource': shot.localSource,
      if (shot.sourceVolume != null) 'sourceVolume': shot.sourceVolume,
    };

Map<String, dynamic> _referenceJson(LineRef ref) {
  final segments = ref.segments;
  return {
    'startMs': ref.startMs,
    'endMs': ref.endMs,
    if (ref.videoPath != null) 'videoPath': ref.videoPath,
    'shots': [
      for (var k = 0; k < segments.length; k++)
        () {
          final (start, end) = segments[k];
          final meta = ref.metaAt(start);
          return {
            'index': k,
            'startMs': start,
            'endMs': end,
            // 参考片这一镜长什么样——**要复刻的就是它**，挑镜头的头号依据
            'description': meta?.description ?? '',
            'tags': meta?.tags ?? const <String>[],
            'asr': ref.segmentText(k, ''),
          };
        }(),
    ],
  };
}

int _lineSpanMs(ScriptLine line) {
  var span = 0;
  for (final s in line.shots) {
    span += s.allocMs ?? 0;
  }
  if (span > 0) return span;
  return ShotAllocation.rootMsOf(line) ?? 0;
}

String _sec(int ms) => (ms / 1000).toStringAsFixed(1);

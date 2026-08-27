import '../core/models/renew_task.dart';
import '../core/script/script_doc.dart';
import '../core/script/subtitle_mismatch.dart';
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
    // 本片基调：这个片子听起来是谁在说话。null = 还没定过，
    // 该先问人再去生成配音（撞运气用系统默认，不对就白烧一轮 TTS）
    'defaultVoiceId': doc.defaultVoiceId,
    'defaultSpeechRate': doc.defaultSpeechRate,
    // 三条声音轨的总控。逐镜原声、逐段配乐是相对值，乘在这上面
    'sound': {
      'source': doc.mix.source,
      'voice': doc.mix.voice,
      'bgm': doc.mix.bgm,
      if (doc.mix.sourceMuted) 'sourceMuted': true,
      if (doc.mix.voiceMuted) 'voiceMuted': true,
      if (doc.mix.bgmMuted) 'bgmMuted': true,
      'duckSourceUnderVoice': doc.mix.duckSourceUnderVoice,
      'duckedSourceVolume': doc.mix.duckedSourceVolume,
    },
    // 老字段名，等同 sound.duckedSourceVolume（口播时原声压到多少）
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
      // 配音没有逐字时间：**断不了句、字幕退回整句**。
      // 原来只 warn 不拦，于是片子导得出来、字幕却是一整段糊在屏幕上
      // （真机撞到：第 16 句「加一点。」ASR 报 no valid speech in audio）
      for (var i = 0; i < doc.lines.length; i++)
        if (doc.lines[i].type == ScriptLineType.voiced &&
            doc.lines[i].voiceover != null &&
            doc.lines[i].voiceover!.words.isEmpty)
          {
            'lineIndex': i,
            'kind': 'no-word-timings',
            'message': '第 ${i + 1} 行的配音没有逐字时间，断不了句——'
                '字幕会整句糊在屏幕上。重新生成这一句的配音试试'
                '（ishkafel script voice <任务> --line ${i + 1}）；'
                '还是不行就把这句台词改一改，太短或只有语气词的句子'
                'ASR 认不出来',
          },
      // 手写字幕盖不住这一屏的语音：不拦导出的话，成片里会出现
      // 「配音在念、字幕停着不动」，人拿到片子才发现
      for (var i = 0; i < doc.lines.length; i++)
        for (final m in subtitleMismatches(doc.lines[i]))
          {
            'lineIndex': i,
            'screenIndex': m.screenIndex,
            'kind': 'subtitle-too-short',
            'message': '第 ${i + 1} 行：${m.message}',
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
    // 划词建镜要用的三样：每个字落在哪、哪些字已经被占住、现在能不能划。
    // 人在界面上是用眼睛看的，Agent 得有等价的东西
    'canPickWords': (vo?.words ?? const []).isNotEmpty,
    if ((vo?.words ?? const []).isNotEmpty)
      'words': [
        for (final w in vo!.words)
          {'text': w.text, 'startMs': w.startMs, 'endMs': w.endMs},
      ],
    'takenWords': [
      for (final s in line.shots)
        if (s.boundToWords) {'start': s.startWord, 'end': s.endWord},
    ],
    // 这一行**实际**会用的音色与语速（行上没设就是本片基调）。
    // 给有效值，Agent 才知道生成出来会是谁在说话
    'voiceId': doc.voiceIdOf(line),
    'speechRate': doc.speechRateOf(line),
    // 但要说清是不是跟随来的：跟随的行会随基调变，单独设过的不会
    if (line.voiceId == null && doc.defaultVoiceId != null)
      'voiceFollowsDoc': true,
    if (line.speechRate == null && doc.defaultSpeechRate != 0)
      'speechRateFollowsDoc': true,
    if (vo != null)
      'voice': {
        // **拿有效值判定**：本片基调换了，跟随基调的那些配音就该报 stale。
        // 用 line.voiceState 会漏掉基调变化——界面说要重配、CLI 说新鲜，
        // Agent 就会拿旧音色直接导出去（静默出错，最要命的那种）
        'state': doc.voiceStateOf(line).name,
        if (vo.voiceId.isNotEmpty) 'voiceId': vo.voiceId,
        'durationMs': vo.durationMs,
        'speechRate': vo.speechRate,
        // 没有逐字时间就不能外包断句——让调用方看得见，别让它算了半天才发现
        'hasWordTimings': vo.words.isNotEmpty,
        if (line.voiceDefectText != null) 'defect': line.voiceDefectText,
      },
    'shots': [
      for (var j = 0; j < line.shots.length; j++)
        _shotJson(line.shots[j], j, words: vo?.words ?? const []),
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

Map<String, dynamic> _shotJson(LineShot shot, int index,
        {List<VoiceWord> words = const []}) =>
    {
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
      // 划词建的镜：绑住台词的哪几个字。时长是**从这个区间算出来的**，
      // 不是存的——换音色、重配音之后朗读长短全变，切点不变、时长自动跟上
      if (shot.boundToWords) ...{
        'startWord': shot.startWord,
        'endWord': shot.endWord,
        // 连文字一起给：不然 Agent 还得自己去拼词，而词表和原文常有出入
        'boundText': _wordsText(words, shot.startWord!, shot.endWord!),
      },
    };

String _wordsText(List<VoiceWord> words, int from, int to) => [
      for (var i = from.clamp(0, words.length);
          i < to.clamp(0, words.length);
          i++)
        words[i].text,
    ].join();

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

/// 断句要用的全部材料。
///
/// 断句是这条线上**最值得外包**的一步：现在软件里的自动分屏是「标点优先 →
/// 停顿次之 → 字数兜底」的启发式，本质是在猜；而断句是纯语言判断，LLM 比
/// 规则强。切点又完全可验证（词序号，三条约束一查即知），符合外包的判据。
///
/// 没有逐字时间就**直接拒绝**，不给一份假材料让它白算一场。
Map<String, dynamic> scriptSubtitleMaterial(ScriptDoc doc, int lineIndex) {
  if (lineIndex < 0 || lineIndex >= doc.lines.length) {
    throw ArgumentError('第 ${lineIndex + 1} 行不存在（脚本共 ${doc.lines.length} 行）');
  }
  final line = doc.lines[lineIndex];
  final vo = line.voiceover;
  final words = vo?.words ?? const <VoiceWord>[];
  if (words.isEmpty) {
    throw ArgumentError('第 ${lineIndex + 1} 行的配音没有逐字时间，断不了句——'
        '重新生成配音后才能断');
  }
  final style = line.subtitleOverride ?? doc.subtitle;
  var span = 0;
  final boundaries = <Map<String, dynamic>>[];
  for (var j = 0; j < line.shots.length; j++) {
    final alloc = line.shots[j].allocMs ?? 0;
    boundaries.add({'shotIndex': j, 'startMs': span, 'endMs': span + alloc});
    span += alloc;
  }
  if (span <= 0) span = vo!.durationMs;
  return {
    'lineIndex': lineIndex,
    'text': line.text,
    'lineSpanMs': span,
    'maxCharsPerScreen': style.maxCharsPerScreen,
    'hasWordTimings': true,
    'words': [
      for (var i = 0; i < words.length; i++)
        {
          'index': i,
          'text': words[i].text,
          'startMs': words[i].startMs,
          'endMs': words[i].endMs,
        },
    ],
    // 一屏跨在两个镜头的接缝上时，观感是字幕在画面切换的瞬间换了一半。
    // **事实给出来，避不避让由 Agent 判断**——软件不替它决定（spec 第一节）
    'shotBoundaries': boundaries,
    'current': {
      'manual': line.subtitleScreens != null,
      'cuts': [
        for (final s in line.subtitleScreens ?? const <SubtitleScreen>[])
          if (s.startWord > 0) s.startWord,
      ],
      'screens': [
        for (final s
            in line.subtitleScreensAt(maxChars: style.maxCharsPerScreen))
          {'startMs': s.startMs, 'endMs': s.endMs, 'text': s.text},
      ],
    },
  };
}

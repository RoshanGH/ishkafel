import '../core/script/script_doc.dart';
import '../core/script/sound_mix.dart';
import '../core/script/shot_allocation.dart';

/// 一条校验失败：**面向调用方的中文原因** + 定位
typedef ApplyIssue = ({int? lineIndex, int? shotIndex, String message});

/// 一行的挑镜结果
typedef ShotPick = ({int lineIndex, List<int> materialIds});

/// 一行的断句结果：切点 = 「从第几个词另起一屏」（0 隐含，不写）
typedef SubtitleCuts = ({int lineIndex, List<int> cuts});

/// 一行的时长分配
typedef AllocSubmission = ({int lineIndex, List<int> allocMs});

/// 一段配乐
typedef BgmSubmission = ({
  int startLine,
  int endLine,
  int materialId,
  double volume,
});

/// 一帧上下的取整零头不算错（帧对齐、倍速折算都会差几十毫秒）
const _toleranceMs = 60;

/// 一屏至少几个字。**只在有切点时才可能触发**——整句两个字的短行压根
/// 不需要切，不受这条影响。挡的是「把一句话切出一个两字屏」那种坏切法：
/// 闪一下就过去，看的人只会觉得晃眼
const _minCharsPerScreen = 4;

/// 校验挑镜提交。空列表 = 通过。**纯函数，不碰 IO**
///
/// [offered] 是本次 `script shots` 给出过的候选：素材 id → 它能出多长成片。
/// 只能从这里面选——不然 Agent 可以凭空编一个 id，而那条素材根本不存在
List<ApplyIssue> validateShotsSubmission({
  required ScriptDoc doc,
  required List<ShotPick> picks,
  required Map<int, int> offered,
}) {
  final issues = <ApplyIssue>[];
  for (final pick in picks) {
    final i = pick.lineIndex;
    if (i < 0 || i >= doc.lines.length) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行不存在（脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    final line = doc.lines[i];
    if (line.type != ScriptLineType.voiced) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行是画面行，镜头由时长决定，不走这里'
      ));
      continue;
    }
    if (pick.materialIds.isEmpty) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行没给镜头——不想配就别提交这一行'
      ));
      continue;
    }
    final seen = <int>{};
    var usable = 0;
    for (final id in pick.materialIds) {
      if (!offered.containsKey(id)) {
        issues.add((
          lineIndex: i,
          shotIndex: null,
          message: '第 ${i + 1} 行的素材 $id 不在候选里——'
              '只能从 script shots 给出的候选里选'
        ));
        continue;
      }
      if (!seen.add(id)) {
        issues.add((
          lineIndex: i,
          shotIndex: null,
          message: '第 ${i + 1} 行重复选了同一条素材 $id'
        ));
        continue;
      }
      usable += offered[id]!;
    }
    final root = ShotAllocation.rootMsOf(line) ?? 0;
    if (root > 0 && usable + _toleranceMs < root) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行的镜头加起来只能出 ${_sec(usable)} 秒，'
            '铺不满 ${_sec(root)} 秒的配音'
      ));
    }
  }
  return issues;
}

/// 校验断句提交。
///
/// 切点是**词序号**（从第几个词另起一屏），完全可验证——这正是断句能外包
/// 给 Agent 的原因（spec 第三节的判据）
List<ApplyIssue> validateSubtitleSubmission({
  required ScriptDoc doc,
  required List<SubtitleCuts> submissions,
}) {
  final issues = <ApplyIssue>[];
  for (final sub in submissions) {
    final i = sub.lineIndex;
    if (i < 0 || i >= doc.lines.length) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行不存在（脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    final line = doc.lines[i];
    final words = line.voiceover?.words ?? const <VoiceWord>[];
    if (words.isEmpty) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行的配音没有逐字时间，断不了句——'
            '重新生成配音后再来'
      ));
      continue;
    }
    final maxChars =
        (line.subtitleOverride ?? doc.subtitle).maxCharsPerScreen;
    var last = 0;
    for (final cut in sub.cuts) {
      if (cut <= 0 || cut >= words.length) {
        issues.add((
          lineIndex: i,
          shotIndex: null,
          message: '第 ${i + 1} 行的切点 $cut 超出范围'
              '（这句共 ${words.length} 个字）'
        ));
        continue;
      }
      if (cut <= last) {
        issues.add((
          lineIndex: i,
          shotIndex: null,
          message: '第 ${i + 1} 行的切点 ${sub.cuts} 不是递增的'
        ));
        break;
      }
      last = cut;
    }
    // 每一屏的字数：太多会出画，太少闪一下就过去
    final bounds = [0, ...sub.cuts.where((c) => c > 0 && c < words.length), words.length];
    for (var k = 0; k + 1 < bounds.length; k++) {
      final chars = bounds[k + 1] - bounds[k];
      if (chars <= 0) continue;
      if (chars > maxChars) {
        issues.add((
          lineIndex: i,
          shotIndex: null,
          message: '第 ${i + 1} 行第 ${k + 1} 屏有 $chars 个字，'
              '超过这个字号一屏能放的 $maxChars 个字——会出画'
        ));
      } else if (chars < _minCharsPerScreen && bounds.length > 2) {
        issues.add((
          lineIndex: i,
          shotIndex: null,
          message: '第 ${i + 1} 行第 ${k + 1} 屏只有 $chars 个字——'
              '闪一下就过去，看的人只会觉得晃眼'
        ));
      }
    }
  }
  return issues;
}

/// 校验时长分配。
///
/// 总和必须严格等于这一行的根：画面轨与声音轨要等长、段段首尾相接，
/// 差一点点就会让整条轨错位（0.1.43/0.1.47 修过两轮）
List<ApplyIssue> validateAllocSubmission({
  required ScriptDoc doc,
  required List<AllocSubmission> submissions,
}) {
  final issues = <ApplyIssue>[];
  for (final sub in submissions) {
    final i = sub.lineIndex;
    if (i < 0 || i >= doc.lines.length) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行不存在（脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    final line = doc.lines[i];
    if (sub.allocMs.length != line.shots.length) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行有 ${line.shots.length} 个镜头，'
            '给了 ${sub.allocMs.length} 个时长'
      ));
      continue;
    }
    final root = ShotAllocation.rootMsOf(line) ?? 0;
    final total = sub.allocMs.fold<int>(0, (a, b) => a + b);
    if (root > 0 && (total - root).abs() > _toleranceMs) {
      issues.add((
        lineIndex: i,
        shotIndex: null,
        message: '第 ${i + 1} 行加起来 ${_sec(total)} 秒，'
            '配音是 ${_sec(root)} 秒——差这一点会让画面与声音错位'
      ));
    }
    for (var j = 0; j < sub.allocMs.length; j++) {
      final want = sub.allocMs[j];
      final shot = line.shots[j];
      if (want < ShotAllocation.minShotMs) {
        issues.add((
          lineIndex: i,
          shotIndex: j,
          message: '第 ${i + 1} 行第 ${j + 1} 镜只有 ${_sec(want)} 秒——'
              '比一眨眼还短'
        ));
        continue;
      }
      if (shot.durationMs != null && want > shot.availableMs + _toleranceMs) {
        issues.add((
          lineIndex: i,
          shotIndex: j,
          message: '第 ${i + 1} 行第 ${j + 1} 镜要 ${_sec(want)} 秒，'
              '这条素材按当前倍速只能出 ${_sec(shot.availableMs)} 秒'
        ));
      }
    }
  }
  return issues;
}

/// 校验配乐分段。
///
/// 配乐轨的模型是**整片被若干刀切成连续段、铺满全片**（0.1.36 定的），
/// 不是「行区间随便标几段」——留洞或重叠都会让预览与成片对不上
List<ApplyIssue> validateBgmSubmission({
  required ScriptDoc doc,
  required List<BgmSubmission> submissions,
  required Set<int> offered,
}) {
  final issues = <ApplyIssue>[];
  final total = doc.lines.length;
  for (final seg in submissions) {
    if (seg.startLine < 0 ||
        seg.endLine >= total ||
        seg.startLine > seg.endLine) {
      issues.add((
        lineIndex: seg.startLine,
        shotIndex: null,
        message: '第 ${seg.startLine + 1}~${seg.endLine + 1} 行超出范围'
            '（脚本共 $total 行）'
      ));
    }
    if (!offered.contains(seg.materialId)) {
      issues.add((
        lineIndex: seg.startLine,
        shotIndex: null,
        message: '配乐 ${seg.materialId} 不在候选里'
      ));
    }
    if (seg.volume < 0 || seg.volume > 1) {
      issues.add((
        lineIndex: seg.startLine,
        shotIndex: null,
        message: '音量 ${seg.volume} 超出范围（0~1）'
      ));
    }
  }
  // 连续铺满：按起点排序后逐行核对
  final sorted = [...submissions]
    ..sort((a, b) => a.startLine.compareTo(b.startLine));
  var cursor = 0;
  for (final seg in sorted) {
    if (seg.startLine > cursor) {
      issues.add((
        lineIndex: cursor,
        shotIndex: null,
        message: '第 ${cursor + 1}~${seg.startLine} 行没有配乐段——'
            '配乐轨是整片切成几段，不能留空档（不要配乐也要显式占一段）'
      ));
    } else if (seg.startLine < cursor) {
      issues.add((
        lineIndex: seg.startLine,
        shotIndex: null,
        message: '第 ${seg.startLine + 1}~${seg.endLine + 1} 行与前一段重叠了'
      ));
    }
    cursor = seg.endLine + 1;
  }
  if (submissions.isNotEmpty && cursor < total) {
    issues.add((
      lineIndex: cursor,
      shotIndex: null,
      message: '第 ${cursor + 1}~$total 行没有配乐段——配乐轨要铺满全片'
    ));
  }
  return issues;
}

String _sec(int ms) => (ms / 1000).toStringAsFixed(1);

/// 改台词 / 增删行
typedef LineEdit = ({
  /// 'set'（改台词）/ 'insert'（在这一行后插入）/ 'remove'（删这一行）
  String op,
  int lineIndex,
  String? text,
});

/// 一镜的编辑：取段、变速、原声音量、删除
typedef ShotEdit = ({
  int lineIndex,
  int shotIndex,
  /// 'trim' / 'speed' / 'volume' / 'remove'
  String op,
  num? value,
});

/// 一屏的文字覆盖
typedef ScreenText = ({int lineIndex, int screenIndex, String? text});

/// 校验行编辑。
///
/// 删行有个硬约束：**至少留一行**——空脚本在界面上是「起步态」，
/// 会弹出引导覆盖工作台，Agent 删空了人打开会一头雾水
List<ApplyIssue> validateLineEdits({
  required ScriptDoc doc,
  required List<LineEdit> edits,
}) {
  final issues = <ApplyIssue>[];
  var count = doc.lines.length;
  for (final e in edits) {
    if (!const ['set', 'insert', 'remove'].contains(e.op)) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '认不出的操作「${e.op}」（可用：set / insert / remove）'
      ));
      continue;
    }
    if (e.lineIndex < 0 || e.lineIndex >= doc.lines.length) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行不存在（脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    if (e.op == 'remove') {
      count--;
      if (count < 1) {
        issues.add((
          lineIndex: e.lineIndex,
          shotIndex: null,
          message: '不能把脚本删空——至少留一行'
        ));
      }
      // 删掉一行会把它的配音、镜头、字幕一起带走，值得说一声
      final line = doc.lines[e.lineIndex];
      if (line.voiceover != null || line.shots.isNotEmpty) {
        issues.add((
          lineIndex: e.lineIndex,
          shotIndex: null,
          message: '第 ${e.lineIndex + 1} 行已经有配音或镜头，删掉就一起没了'
              '——确定要删就先把它的镜头清掉'
        ));
      }
    } else if ((e.text ?? '').trim().isEmpty && e.op == 'set') {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行给了空台词——'
            '想变成画面行就把 text 留空并另行设置时长'
      ));
    } else if (e.op == 'insert') {
      count++;
    }
  }
  return issues;
}

/// 校验镜头编辑
List<ApplyIssue> validateShotEdits({
  required ScriptDoc doc,
  required List<ShotEdit> edits,
}) {
  final issues = <ApplyIssue>[];
  for (final e in edits) {
    if (e.lineIndex < 0 || e.lineIndex >= doc.lines.length) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: e.shotIndex,
        message: '第 ${e.lineIndex + 1} 行不存在（脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    final line = doc.lines[e.lineIndex];
    if (e.shotIndex < 0 || e.shotIndex >= line.shots.length) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: e.shotIndex,
        message: '第 ${e.lineIndex + 1} 行没有第 ${e.shotIndex + 1} 镜'
            '（这一行共 ${line.shots.length} 镜）'
      ));
      continue;
    }
    final shot = line.shots[e.shotIndex];
    final v = e.value;
    switch (e.op) {
      case 'remove':
        break;
      case 'trim':
        if (v == null || v < 0) {
          issues.add((
            lineIndex: e.lineIndex,
            shotIndex: e.shotIndex,
            message: '取段起点要给一个非负毫秒数'
          ));
        } else if (shot.durationMs != null && v >= shot.durationMs!) {
          issues.add((
            lineIndex: e.lineIndex,
            shotIndex: e.shotIndex,
            message: '取段起点 ${v}ms 超出这条素材的长度'
                '（${shot.durationMs}ms）'
          ));
        }
      case 'speed':
        if (v == null || v < 0.5 || v > 2.0) {
          issues.add((
            lineIndex: e.lineIndex,
            shotIndex: e.shotIndex,
            message: '倍速要在 0.5~2.0 之间（给的是 $v）'
          ));
        }
      case 'volume':
        if (v == null || v < 0 || v > 1) {
          issues.add((
            lineIndex: e.lineIndex,
            shotIndex: e.shotIndex,
            message: '原声音量要在 0~1 之间（给的是 $v）'
          ));
        }
      default:
        issues.add((
          lineIndex: e.lineIndex,
          shotIndex: e.shotIndex,
          message: '认不出的操作「${e.op}」（可用：trim / speed / volume / remove）'
        ));
    }
  }
  return issues;
}

/// 校验每屏改字。
///
/// **只能改这一屏说了什么，不能凭空加内容**：字幕是给人念出来的话配的字，
/// 与配音对不上就是错的。所以只允许「与原文同长或更短」——同音改写、
/// 去掉语气词都行，长篇加戏不行
List<ApplyIssue> validateScreenTexts({
  required ScriptDoc doc,
  required List<ScreenText> edits,
}) {
  final issues = <ApplyIssue>[];
  for (final e in edits) {
    if (e.lineIndex < 0 || e.lineIndex >= doc.lines.length) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行不存在（脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    final line = doc.lines[e.lineIndex];
    final screens = line.subtitleScreensAt(
        maxChars: (line.subtitleOverride ?? doc.subtitle).maxCharsPerScreen);
    if (e.screenIndex < 0 || e.screenIndex >= screens.length) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行没有第 ${e.screenIndex + 1} 屏'
            '（这一行共 ${screens.length} 屏）'
      ));
      continue;
    }
    final text = e.text;
    if (text == null || text.isEmpty) continue; // null = 回到原文，'' = 不出字
    final was = screens[e.screenIndex].text;
    if (text.length > was.length + 2) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行第 ${e.screenIndex + 1} 屏原本是'
            '「$was」（${was.length} 字），改成了 ${text.length} 字——'
            '字幕要跟着念出来的话走，不能凭空加内容'
      ));
    }
  }
  return issues;
}

/// 一行的音色/语速改动。null = 这一项不动
typedef LineVoiceEdit = ({int lineIndex, String? voiceId, int? speechRate});

/// 校验「改本片基调」。
///
/// 基调是这个片子听起来是谁在说话：行上没单独设的都跟着它走，
/// 换了之后已经生成的配音会被判成过期（见 [ScriptDoc.voiceStateOf]）。
List<ApplyIssue> validateBaselineSubmission({
  required ScriptDoc doc,
  required String? voiceId,
  required int? speechRate,
}) {
  final issues = <ApplyIssue>[];
  // 空提交不是「什么都不改」：多半是字段名写错了，当成成功更糟
  if (voiceId == null && speechRate == null) {
    return [
      (lineIndex: null, shotIndex: null, message: '既没给音色也没给语速，这一批什么都没说')
    ];
  }
  if (voiceId != null && voiceId.trim().isEmpty) {
    issues.add((
      lineIndex: null,
      shotIndex: null,
      message: '音色 id 是空的。要「回到没设过」请直接省掉这个字段，'
          '空串会静默生效成一个不存在的音色'
    ));
  }
  if (speechRate != null && (speechRate < -50 || speechRate > 100)) {
    issues.add((
      lineIndex: null,
      shotIndex: null,
      message: '语速要在 -50~100 之间（火山口径：0 = 原速、100 = 2 倍速、'
          '-50 = 0.5 倍速），给的是 $speechRate'
    ));
  }
  return issues;
}

/// 校验「改某几行的音色/语速」。
///
/// 与基调的区别：这里写的是**逐行覆盖**，其他行不受影响。人特意点了
/// 这几行才用它；要改全片用基调。
List<ApplyIssue> validateLineVoiceSubmission({
  required ScriptDoc doc,
  required List<LineVoiceEdit> edits,
}) {
  if (edits.isEmpty) {
    return [(lineIndex: null, shotIndex: null, message: '一行都没给')];
  }
  final issues = <ApplyIssue>[];
  for (final e in edits) {
    if (e.lineIndex < 0 || e.lineIndex >= doc.lines.length) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '没有第 ${e.lineIndex + 1} 行（这个脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    final line = doc.lines[e.lineIndex];
    if (line.type != ScriptLineType.voiced) {
      // 静默忽略的话，人以为改了 8 行，实际只有 5 行生效
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行是画面行（没有台词、不生成配音），'
            '改它的音色/语速没有意义'
      ));
      continue;
    }
    if (e.voiceId == null && e.speechRate == null) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行既没给音色也没给语速'
      ));
      continue;
    }
    if (e.voiceId != null && e.voiceId!.trim().isEmpty) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行的音色 id 是空的'
      ));
    }
    final rate = e.speechRate;
    if (rate != null && (rate < -50 || rate > 100)) {
      issues.add((
        lineIndex: e.lineIndex,
        shotIndex: null,
        message: '第 ${e.lineIndex + 1} 行的语速要在 -50~100 之间（给的是 $rate）'
      ));
    }
  }
  return issues;
}

/// 校验「改三轨混音台」。
///
/// 数值本身由 [SoundMix] 夹在 0~1，这里管的是**说得通吗**。
List<ApplyIssue> validateMixSubmission({
  required ScriptDoc doc,
  required SoundMix mix,
}) {
  // 三条轨全关 = 一段哑片。这不该静默通过：真要哑片的人不会用这种方式做，
  // 而搞错了的人会一路导到成片才发现
  if (mix.effectiveSource <= 0.001 &&
      mix.effectiveVoice <= 0.001 &&
      mix.effectiveBgm <= 0.001) {
    return [
      (
        lineIndex: null,
        shotIndex: null,
        message: '原声、口播、配乐三条轨都被关掉了——这样导出来是一段哑片。'
            '确认是要这样的话，单独把想留的那条打开'
      )
    ];
  }
  return const [];
}

/// 一次划词建镜：给这一行的第 `[startWord, endWord)` 个字配一个画面
typedef WordShotPick = ({
  int lineIndex,
  int startWord,
  int endWord,
  int materialId,
});

/// 校验划词建镜。**人在界面上能干的，Agent 要能干同一件事**。
///
/// 界面那边是「已经被占住的字划不动」——选中它根本不出按钮，人不做无效
/// 操作。Agent 这边没有界面挡着，所以规则要在这里说清并拒绝，
/// 而且要点名该先删哪一镜。
List<ApplyIssue> validateWordShotSubmission({
  required ScriptDoc doc,
  required List<WordShotPick> picks,
  required Set<int> offered,
}) {
  if (picks.isEmpty) {
    return [(lineIndex: null, shotIndex: null, message: '一个都没给')];
  }
  final issues = <ApplyIssue>[];
  // 同一批里的区间也要互相查：一次提交两段重叠的，落盘后同样是坏结构
  final claimed = <int, List<({int start, int end})>>{};

  for (final p in picks) {
    if (p.lineIndex < 0 || p.lineIndex >= doc.lines.length) {
      issues.add((
        lineIndex: p.lineIndex,
        shotIndex: null,
        message: '没有第 ${p.lineIndex + 1} 行（这个脚本共 ${doc.lines.length} 行）'
      ));
      continue;
    }
    final line = doc.lines[p.lineIndex];
    final words = line.voiceover?.words ?? const <VoiceWord>[];
    if (words.isEmpty) {
      // 没有逐字时间就算不出「这几个字读多久」，这一镜的时长无从谈起
      issues.add((
        lineIndex: p.lineIndex,
        shotIndex: null,
        message: '第 ${p.lineIndex + 1} 行还没有配音（或配音没有逐字时间），'
            '划词建镜要靠它算时长——先 ishkafel script voice 生成配音'
      ));
      continue;
    }
    if (p.startWord < 0 ||
        p.endWord > words.length ||
        p.endWord <= p.startWord) {
      issues.add((
        lineIndex: p.lineIndex,
        shotIndex: null,
        message: '第 ${p.lineIndex + 1} 行的字区间 [${p.startWord}, ${p.endWord}) '
            '不成立（这一句共 ${words.length} 个字，起点要小于终点）'
      ));
      continue;
    }
    if (!offered.contains(p.materialId)) {
      issues.add((
        lineIndex: p.lineIndex,
        shotIndex: null,
        message: '素材 ${p.materialId} 不在候选里。'
            '只能用 ishkafel script shots 返回过的素材，不要凭空造 id'
      ));
      continue;
    }
    // 和已经在盘上的划词镜比
    for (var j = 0; j < line.shots.length; j++) {
      final s = line.shots[j];
      if (!s.boundToWords) continue;
      if (p.startWord < s.endWord! && s.startWord! < p.endWord) {
        issues.add((
          lineIndex: p.lineIndex,
          shotIndex: j,
          message: '第 ${p.lineIndex + 1} 行的 [${p.startWord}, ${p.endWord}) '
              '和第 ${j + 1} 镜的 [${s.startWord}, ${s.endWord}) 重叠了。'
              '同一个字不能既属于这一镜又属于那一镜——'
              '先删掉第 ${j + 1} 镜（apply shot-edit 的 remove）再划'
        ));
        break;
      }
    }
    // 再和同一批里前面几条比
    final mine = claimed[p.lineIndex] ??= [];
    if (mine.any((r) => p.startWord < r.end && r.start < p.endWord)) {
      issues.add((
        lineIndex: p.lineIndex,
        shotIndex: null,
        message: '这一批里第 ${p.lineIndex + 1} 行有两段字区间互相重叠了'
      ));
      continue;
    }
    mine.add((start: p.startWord, end: p.endWord));
  }
  return issues;
}

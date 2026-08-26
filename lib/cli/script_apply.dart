import '../core/script/script_doc.dart';
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

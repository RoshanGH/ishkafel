import '../playback/track_plan.dart';
import 'script_doc.dart';
import 'shot_coverage.dart';
import 'shot_allocation.dart';

/// 一个镜头段的画面来源：文件路径 + 从文件的哪一刻开始播。
///
/// 原速镜头直接播素材本体（inMs = 框选起点）；变速镜头播的是预渲染好的
/// 对齐切片（从 0 开始、时长恰为 allocMs——EDL 没有逐段倍速，见 Edl 注释）
class ShotSource {
  final String path;
  final int inMs;
  const ShotSource(this.path, {this.inMs = 0});
}

/// 整片预览的构建结果：可播的轨 + 这一轮跳过了什么（必须说出来）
class ScriptPlanResult {
  final TrackPlan plan;

  /// 被跳过的行（0 起下标）→ 人话原因。预览可以少一行——人还在编排——
  /// 但少了哪行、为什么少，必须点名
  final Map<int, String> skippedLines;

  /// 进了预览的行 → 它在预览轴上的起点（「点句子跳播」靠它）
  final Map<int, int> lineStarts;

  const ScriptPlanResult({
    required this.plan,
    required this.skippedLines,
    this.lineStarts = const {},
  });

  bool get isEmpty => plan.isEmpty;
}

/// 把脚本拼成预览轨：画面 = 各行镜头序列顺序相接，口播 = 各行配音。
///
/// **只拼就绪的行**：行的时长根不存在（没配音/没填时长）、镜头没挑、
/// 分配没做完、素材没下载完，这一行都进不了预览——预览轴是「已就绪内容」
/// 的连续拼接，跳过的行逐条点名，绝不静默把片子变短。
ScriptPlanResult buildScriptTrackPlan(
  ScriptDoc doc, {
  required ShotSource? Function(LineShot shot) sourceOf,

  /// 配乐曲子的本地路径（materialId → path）；null = 还没下载好，
  /// 该段先不铺（由调用方交代下载状态）
  String? Function(int materialId)? bgmPathOf,

  /// 配音文件是否还在（撤销可能把数据回滚到已被清理的旧文件上）。
  /// null = 不检查（纯函数场景）；页面注入 File.existsSync
  bool Function(String path)? voiceOk,

  /// 口播轨上这一段该用哪个**已规范化**的文件。
  ///
  /// 口播轨是把几十段音频拼成一条流播的，规格一变播放器就要停下来重搭
  /// 音频链路——画面轨上同样的接缝让主时钟卡死过（真机：一个词反复念
  /// 十几遍）。所以进这条轨的每一段都预先转成同规格、并补足到坑位那么长
  /// （见 [PreviewVoiceNormalizer]）。
  ///
  /// [kind] 是 'voice'（配音行）或 'shot'（画面行用素材自己的声音）。
  /// 返回 null = 这一段还没准备好，这一行先不进预览
  String? Function({
    required String kind,
    required String source,
    required int inMs,
    required int durationMs,
    required double speed,
  })? voiceSegmentOf,
}) {
  final video = <TrackSegment>[];
  final voice = <TrackSegment>[];
  final skipped = <int, String>{};
  final lineStarts = <int, int>{};
  var cursorMs = 0;

  for (var i = 0; i < doc.lines.length; i++) {
    final line = doc.lines[i];
    final blank =
        line.text.trim().isEmpty && line.shots.isEmpty; // 纯空行不值得点名
    if (blank) continue;

    final root = ShotAllocation.rootMsOf(line);
    if (root == null || root <= 0) {
      skipped[i] = line.type == ScriptLineType.voiced
          ? '还没生成配音（配音时长是这一行的根）'
          : '还没确定时长';
      continue;
    }
    final lineVo = line.voiceover;
    if (line.type == ScriptLineType.voiced &&
        lineVo != null &&
        voiceOk != null &&
        !voiceOk(lineVo.audioPath)) {
      // 死链配音不进 EDL——那会静默播出一段没有声音的台词
      skipped[i] = '配音文件丢失（点「重配」重新生成即可）';
      continue;
    }
    if (line.shots.isEmpty) {
      skipped[i] = '还没挑镜头';
      continue;
    }
    if (line.shots.any((s) => s.allocMs == null)) {
      skipped[i] = '镜头还没分时长';
      continue;
    }
    final sources = <ShotSource>[];
    String? notReady;
    for (final shot in line.shots) {
      final src = sourceOf(shot);
      if (src == null) {
        notReady = '素材还没就绪（下载或变速切片未完成）';
        break;
      }
      sources.add(src);
    }
    if (notReady != null) {
      skipped[i] = notReady;
      continue;
    }
    // 画面铺不满坑位 = 阻断。让它进预览只会两头错：画面轨按 EDL 声明的
    // 长度算，mpv 读到文件尾就收，整条轨缩水，配音被反复拽回同一处
    // （听起来就是台词一直在重复）；成片那边则是画面定格几秒。
    // 宁可这一行不播，也不能播一个错的（真机踩过）
    final gaps = lineShotGaps(line);
    if (gaps.isNotEmpty) {
      final g = gaps.first;
      skipped[i] = '第 ${g.shotIndex + 1} 镜的画面只有 ${_sec(g.usableMs)} 秒，'
          '铺不满 ${_sec(g.allocMs)} 秒（差 ${_sec(g.gapMs)} 秒）——'
          '换条长一点的素材、放慢这一镜，或把它截短';
      continue;
    }

    lineStarts[i] = cursorMs;
    var shotAt = cursorMs;
    for (var j = 0; j < line.shots.length; j++) {
      final shot = line.shots[j];
      video.add(TrackSegment(
        atMs: shotAt,
        durationMs: shot.allocMs!,
        source: sources[j].path,
        inMs: sources[j].inMs,
        // 这一镜的素材原声出多大——**画面轨不出声，这个数交给原声轨**。
        // 两种行的默认不同（配音行跟全片、画面行满音量），但只此一处算：
        // 界面上的滑杆读的是同一个数，不然会出现「显示静音、实际在响」
        volume: doc.sourceVolumeFor(line, shot),
      ));
      // 画面行没有配音，用素材自己的声音（设计稿：画面行有画面有音乐
      // 或用分镜自己的声音）；配音行的声音轨在下面统一铺配音
      if (line.type == ScriptLineType.visual) {
        // 画面行没有配音，口播轨在这一段垫同规格的静音——**不能留空档**，
        // EDL 会把空档直接压掉，后面每一句都提前一截。
        // 它真正的声音（素材自己的）走**原声轨**：那条轨按镜头逐段加载、
        // 逐段设音量，所以「这一镜的原声调到 35%」才能生效，播放中改也
        // 立刻听得到
        String? mute;
        if (voiceSegmentOf != null) {
          mute = voiceSegmentOf(
            kind: 'mute',
            source: '',
            inMs: 0,
            durationMs: shot.allocMs!,
            speed: 1.0,
          );
          if (mute == null) {
            notReady = '这一镜的声音还在准备（预览要把各段声音统一规格）';
            break;
          }
        }
        voice.add(TrackSegment(
          atMs: shotAt,
          durationMs: shot.allocMs!,
          // 没接规范化器时（测试/精简装配）退回素材本身：可能在接缝处
          // 卡一下，但至少听得到
          source: mute ?? sources[j].path,
          inMs: mute == null ? sources[j].inMs : 0,
          volume: mute == null ? doc.sourceVolumeFor(line, shot) : 1.0,
        ));
      }
      shotAt += shot.allocMs!;
    }
    // 行区间跟**实际分配**走：画面轨必须连续（EDL 是顺序相接的，留洞会让
    // 画面与声音错位）。分配不足根时配音随画面截断——缺口在分配警告里
    // 已经点过名，预览如实播出「画面只有这么长」
    final lineSpanMs = shotAt - cursorMs;
    final vo = line.voiceover;
    if (line.type == ScriptLineType.voiced && vo != null && lineSpanMs > 0) {
      // 配音也走规范化：**输出严格等于这一行的画面长度**——短了在尾巴上
      // 垫静音、长了截断。声音轨因此与画面轨严格等长、段段首尾相接，
      // 既不会留洞（洞会被 EDL 压掉、后面全部提前），也不会因为插一段
      // 异构的静音文件而制造新的接缝
      String? seg;
      if (voiceSegmentOf != null) {
        seg = voiceSegmentOf(
          kind: 'voice',
          source: vo.audioPath,
          inMs: 0,
          durationMs: lineSpanMs,
          speed: 1.0,
        );
        if (seg == null) {
          skipped[i] = '这一句的声音还在准备（预览要把各段声音统一规格）';
          video.removeRange(video.length - line.shots.length, video.length);
          lineStarts.remove(i);
          continue;
        }
      }
      voice.add(TrackSegment(
        atMs: cursorMs,
        // 没接规范化器时退回原配音：短于画面就按配音长度铺（旧行为）
        durationMs: seg != null
            ? lineSpanMs
            : (root < lineSpanMs ? root : lineSpanMs),
        source: seg ?? vo.audioPath,
      ));
    }
    cursorMs = shotAt;
  }

  // 配乐段：行区间 → 预览轴区间（只算进了预览的行）。
  // 相邻段同一首曲子时合并成一个 clip——播放连续不重头
  // （BgmSegment 引擎的同一语义）
  final bgm = <BgmTrackSegment>[];
  for (final seg in doc.bgmSegments) {
    final path = bgmPathOf?.call(seg.material.id);
    if (path == null) continue;
    int? fromMs;
    var toMs = 0;
    for (var i = seg.startLine; i <= seg.endLine && i < doc.lines.length; i++) {
      final start = lineStarts[i];
      if (start == null) continue; // 该行没进预览
      fromMs ??= start;
      final nextStart = lineStarts.entries
          .where((e) => e.key > i)
          .fold<int?>(null, (a, e) => a == null || e.value < a ? e.value : a);
      toMs = nextStart ?? cursorMs;
    }
    if (fromMs == null || toMs <= fromMs) continue;
    final last = bgm.isEmpty ? null : bgm.last;
    if (last != null &&
        last.clip.source == path &&
        last.clip.endMs == fromMs &&
        last.volume == doc.bgmVolumeOf(seg.volume)) {
      // 相邻同曲：并成一段，接着播不重头
      bgm[bgm.length - 1] = BgmTrackSegment(
        clip: TrackSegment(
            atMs: last.clip.atMs,
            durationMs: toMs - last.clip.atMs,
            source: path),
        volume: last.volume,
        sourceDurationMs: last.sourceDurationMs,
      );
    } else {
      bgm.add(BgmTrackSegment(
        clip: TrackSegment(
            atMs: fromMs, durationMs: toMs - fromMs, source: path),
        // 段上设的是相对值，乘在配乐轨总音量上——拉总音量，
        // 单独调过的段落也跟着变
        volume: doc.bgmVolumeOf(seg.volume),
        sourceDurationMs: seg.material.durationMs,
      ));
    }
  }
  return ScriptPlanResult(
    plan: TrackPlan(
        video: video,
        voice: voice,
        bgm: bgm,
        // 口播轨是整条 EDL 加载的，逐段音量表达不了——总音量按轨给
        voiceVolume: doc.voiceVolume),
    skippedLines: skipped,
    lineStarts: lineStarts,
  );
}

/// 毫秒 → 一位小数的秒（提示语里给人看的）
String _sec(int ms) => (ms / 1000).toStringAsFixed(1);

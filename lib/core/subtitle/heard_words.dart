import '../analysis/providers.dart' show AsrSentence;
import '../models/semantic_unit.dart';
import '../timeline/composed_frames.dart';
import 'voice_source.dart';

/// 听到的一个字（或一个词）落在成片帧轴的哪几帧
class HeardWord {
  final String text;
  final int firstFrame;
  final int lastFrame;
  final double? confidence;

  /// 这个字的尾巴越过了本镜末帧，落到了哪一镜（`U2S4` 这种写法）。
  /// **没越界就是 null**——这个字段就是「第二句的最后一个字其实是下一个
  /// 镜头的第一个字」那句话的机械表达
  final String? spillsInto;

  const HeardWord({
    required this.text,
    required this.firstFrame,
    required this.lastFrame,
    this.confidence,
    this.spillsInto,
  });
}

/// 这一镜的画面里，耳朵听到的是什么。
///
/// **这不是「该显示什么」**：显示什么是判断，归 Agent。这里只给事实。
class Heard {
  final String text;

  /// 逐字位置。**null = 这一段给不了准数**（原因在 [note] 里），
  /// 不是「没听到」——两件事要分得开
  final List<HeardWord>? words;

  /// 给不了准数时的理由。给得了就是 null
  final String? note;

  const Heard({required this.text, this.words, this.note});
}

Heard heardInShot({
  required ComposedFrames frames,
  required List<SemanticUnit> units,
  required int unitIndex,
  required int shotIndex,
  required VoiceSource source,
  required List<AsrSentence> originalSentences,
}) {
  if (unitIndex < 0 || unitIndex >= units.length) {
    return const Heard(text: '', note: '这个单元下标不存在');
  }
  final unit = units[unitIndex];
  if (shotIndex < 0 || shotIndex >= unit.shots.length) {
    return const Heard(text: '', note: '这个镜头下标不存在');
  }

  switch (source) {
    case VoiceSource.none:
      return const Heard(
          text: '', note: '这个单元是手动加的，原片里没有它，没有台词来源');
    case VoiceSource.replaced:
      // **不编假数字**：整体替换的时长跟着素材走，原片那几句话在成片里被
      // 拉长或压短了，逐词的帧位置只能按比例摊——那是近似值
      return const Heard(
          text: '',
          note: '整段替换，这一段的台词时间在成片里已经不成立，不给逐字位置');
    case VoiceSource.base:
      // 底片自己的转写，时间戳是**素材内**毫秒
      //
      // **null 和空列表是两个事实**（见 SemanticUnit.baseSentences 的注释）：
      // null = 还没转写过；空列表 = 转过、这条素材没人说话。写死一句
      // emptyNote 会把后者也说成「还没转写」——Agent 照着这句话会去触发
      // 一次根本没必要的转写。voice_source.dart 已经分对了，这里不能开倒车。
      final baseSentences = unit.baseSentences;
      return _project(
        frames: frames,
        units: units,
        unitIndex: unitIndex,
        shotIndex: shotIndex,
        sentences: baseSentences ?? const [],
        // 素材内偏移：镜头坐标减掉单元起点
        shotStartInAxis: unit.shots[shotIndex].startMs - unit.startMs,
        shotEndInAxis: unit.shots[shotIndex].endMs - unit.startMs,
        wordOffsetToUnit: (ms) => ms,
        // 转写过（哪怕是空列表）就交给 _project 的默认文案，跟 original 那一档一致
        emptyNote: baseSentences == null
            ? '这一段固定了底片，但它还没转写过，没有台词可取'
            : null,
      );
    case VoiceSource.original:
      return _project(
        frames: frames,
        units: units,
        unitIndex: unitIndex,
        shotIndex: shotIndex,
        sentences: originalSentences,
        shotStartInAxis: unit.shots[shotIndex].startMs - unit.startMs,
        shotEndInAxis: unit.shots[shotIndex].endMs - unit.startMs,
        // 原片毫秒 → 单元内偏移
        wordOffsetToUnit: (ms) => ms - unit.startMs,
        emptyNote: null,
      );
  }
}

/// 把词投影到成片帧轴。
///
/// 镜头替换是变速对齐回原坑位、**时长不变**，所以单元内偏移在成片里 1:1 成立：
/// 成片毫秒 = 这个单元在成片里的起点 + 单元内偏移。
Heard _project({
  required ComposedFrames frames,
  required List<SemanticUnit> units,
  required int unitIndex,
  required int shotIndex,
  required List<AsrSentence> sentences,
  required int shotStartInAxis,
  required int shotEndInAxis,
  required int Function(int ms) wordOffsetToUnit,
  required String? emptyNote,
}) {
  final unitStart = frames.timeline.startOf(unitIndex);
  final shotSpan = frames.shotSpan(unitIndex, shotIndex);
  final out = <HeardWord>[];

  for (final s in sentences) {
    for (final w in s.words) {
      final from = wordOffsetToUnit(w.startMs);
      final to = wordOffsetToUnit(w.endMs);
      // **成员判定和位置显示必须用同一把尺子。** 原来成员判定用毫秒、
      // 位置显示用帧，同一个函数两条轴：毫秒上跟这一镜还沾一点边、帧上
      // 一帧都不沾的词照样被算进来，还因为「末帧超出本镜末帧」被报成
      // wordSplit——真机任务 #1 有 5 个词是这样，而它们**根本没有
      // 「后半截」**，同一个字在隔壁镜的 words 里又完整出现一次。
      // Agent 照手册把 heard 和 lines 并排看，会判成「漏字」去补，
      // 把对的那一镜改错
      final span = frames.spanOfMs(unitStart + from, unitStart + to);
      // shotSpan 为 null（整块段落）时帧上无从判起，退回毫秒兜底——
      // 那种段落本来也走不到这里（replaced 档在上面就返回了），
      // 留着是为了别让意外的调用崩掉
      final overlaps = shotSpan == null
          ? to > shotStartInAxis && from < shotEndInAxis
          : span.first <= shotSpan.last && span.last >= shotSpan.first;
      if (!overlaps) continue;
      final firstFrame = span.first;
      final lastFrame = span.last;
      out.add(HeardWord(
        text: w.text,
        firstFrame: firstFrame,
        lastFrame: lastFrame,
        confidence: w.confidence,
        spillsInto: shotSpan != null && lastFrame > shotSpan.last
            ? _landsOn(frames, units, unitIndex, shotIndex, lastFrame)
            : null,
      ));
    }
  }

  if (out.isEmpty) {
    return Heard(text: '', note: emptyNote ?? '这一镜的画面里没有人说话');
  }
  return Heard(text: [for (final w in out) w.text].join(), words: out);
}

/// 这个词的尾巴越过本镜末帧之后，**真正落在哪一镜**。
///
/// 原来无条件报「紧邻的下一镜」——可判据只是「超过了本镜末帧」，并没有
/// 验证它真的落在下一镜里。一条片子要切 25~45 镜，短镜头很常见，一个词
/// 完全可能跨过不止一镜，那时报出来的标号是错的，**而 Agent 会拿它当
/// 精确事实去挪字**。
///
/// 所以这里往后逐镜走（必要时跨单元），找到帧区间真正包住 [frame] 的
/// 那一镜。碰到整块段落、或者越过片尾，就**如实说是什么情况**——
/// 不编一个标号出来。
String _landsOn(
  ComposedFrames frames,
  List<SemanticUnit> units,
  int unitIndex,
  int shotIndex,
  int frame,
) {
  var u = unitIndex;
  var s = shotIndex + 1;
  while (u < units.length) {
    if (s >= units[u].shots.length) {
      u++;
      s = 0;
      continue;
    }
    final span = frames.shotSpan(u, s);
    // 整块段落没有镜头可定位（整体替换把那一段整个换掉了）
    if (span == null) return '下一段是整段替换，没有镜头可定位';
    if (frame <= span.last) return 'U${u + 1}S${s + 1}';
    s++;
  }
  return '片尾之后';
}

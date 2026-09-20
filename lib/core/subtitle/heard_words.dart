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
      return _project(
        frames: frames,
        units: units,
        unitIndex: unitIndex,
        shotIndex: shotIndex,
        sentences: unit.baseSentences ?? const [],
        // 素材内偏移：镜头坐标减掉单元起点
        shotStartInAxis: unit.shots[shotIndex].startMs - unit.startMs,
        shotEndInAxis: unit.shots[shotIndex].endMs - unit.startMs,
        wordOffsetToUnit: (ms) => ms,
        emptyNote: '这一段固定了底片，但它还没转写过，没有台词可取',
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
      // 只要跟这一镜有重叠就算「这一镜听得到」
      if (to <= shotStartInAxis || from >= shotEndInAxis) continue;
      final firstFrame = frames.frameAt(unitStart + from);
      final lastFrame = frames.frameAt(unitStart + to);
      out.add(HeardWord(
        text: w.text,
        firstFrame: firstFrame,
        lastFrame: lastFrame,
        confidence: w.confidence,
        spillsInto: shotSpan != null && lastFrame > shotSpan.last
            ? _labelOf(units, unitIndex, shotIndex + 1)
            : null,
      ));
    }
  }

  if (out.isEmpty) {
    return Heard(text: '', note: emptyNote ?? '这一镜的画面里没有人说话');
  }
  return Heard(text: [for (final w in out) w.text].join(), words: out);
}

/// `U2S4` 这种人话写法。越到下一个单元的第一镜也认
String _labelOf(List<SemanticUnit> units, int unitIndex, int shotIndex) {
  if (shotIndex < units[unitIndex].shots.length) {
    return 'U${unitIndex + 1}S${shotIndex + 1}';
  }
  if (unitIndex + 1 < units.length) return 'U${unitIndex + 2}S1';
  return '片尾之后';
}

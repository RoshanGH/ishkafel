import '../models/semantic_unit.dart';
import '../replacement/replacement_plan.dart';
import '../replacement/unit_base.dart';

/// 这一镜的台词从哪来。**四态必须分开**——四种「没台词」长得一模一样的话，
/// Agent 会把「这一段本来就没字幕」当成漏字去修。
enum VoiceSource {
  /// 声音来自原片，`task.asrSentences` 可用
  original,

  /// 这一段固定了底片，台词来自 `unit.baseSentences`（时间戳是素材内毫秒）
  base,

  /// 整段替换：画面来自别的素材，原片 ASR 在这一段一个字都不能用，
  /// 而且成片这一段本来也不烧台词字幕
  replaced,

  /// 手动加的单元（`hasSource == false`），原片里没有它
  none,
}

/// 判这一镜的台词来源，连**一句人话的理由**一起给。
///
/// 只给枚举不给理由的话，Agent 还得回手册里查每一档什么意思——
/// 而手册和实际对不上是这个项目反复栽的一类洞。
({VoiceSource source, String note}) voiceSourceOf({
  required SemanticUnit unit,
  required UnitReplacement replacement,
}) {
  if (!unit.hasSource) {
    return (
      source: VoiceSource.none,
      note: '这个单元是手动加的，原片里没有它，没有台词来源',
    );
  }
  if (hasOwnBaseShots(unit)) {
    return (
      source: VoiceSource.base,
      note: '这一段固定了底片，台词来自素材自己的转写（时间戳是素材内的）',
    );
  }
  // **「还没挑」不是「换掉了」**：整体替换但一条候选都没选时画面照旧
  if (replacement.mode == ReplacementMode.whole &&
      replacement.wholeCandidateIds.isNotEmpty) {
    return (
      source: VoiceSource.replaced,
      note: '整段替换，画面来自别的素材；原片 ASR 在这一段一个字都不能用，'
          '成片里这一段也不会烧台词字幕',
    );
  }
  return (
    source: VoiceSource.original,
    note: '这一镜的声音来自原片，ASR 可用',
  );
}

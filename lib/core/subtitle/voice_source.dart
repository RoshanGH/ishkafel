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
  // **先问底片，再问原片。** 反过来的话，固定过底片的手动单元
  // （hasSource == false）会先掉进 none，报成「没有台词来源」——
  // 而它其实有台词，在 unit.baseSentences 里。Agent 照着这句话会把
  // 「有台词但来源不是原片」当成「本来就没有」，去给它瞎凑字幕。
  //
  // 这个优先级跟 unit_base.dart 的 baseChoiceOf() 是同一条：
  // 底片被固定过就压过一切。两处走岔的话，界面和 Agent 看到的会是两回事。
  if (hasOwnBaseShots(unit)) {
    // **切分和转写是两件事，切成功不代表转写也成功**（base_pin_ops.pin()
    // 的 sentences 参数就明写了「null = 没转成」）。这里不分清楚的话，
    // 这句 note 会对着一份空数据说死话——而 Agent 是照着它去找台词的
    return (
      source: VoiceSource.base,
      note: unit.baseSentences == null
          ? '这一段固定了底片，但那条素材「还没转写过」，取不到台词'
          : '这一段固定了底片，台词来自素材自己的转写（时间戳是素材内的）',
    );
  }
  if (!unit.hasSource) {
    return (
      source: VoiceSource.none,
      note: '这个单元是手动加的，原片里没有它，没有台词来源',
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

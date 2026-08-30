import '../core/export/subtitle_coverage.dart';
import '../core/models/semantic_unit.dart';
import '../core/replacement/replacement_plan.dart';
import '../core/replacement/brand_consistency.dart';
import '../core/replacement/picked_material.dart';
import '../core/subtitle/subtitle_style.dart';
import '../features/picking/burned_text_warning.dart';

/// 导出前要说清的「这批素材有什么问题」。
///
/// 导出是**花钱花时间的最后一步**，出来的就是要交付的片子。界面上的导出
/// 确认页会点名，纯命令行这条路一度一声不吭——Agent 查得到
/// （`task --json` 里有），但导出时不提，等于把「要不要用这条素材」
/// 这个判断悄悄跳过了。
///
/// **不拦**：要不要继续是调用方的判断，和「多少条、多大、导到哪」同一档。
/// 但绝不能不说。
List<String> exportWarnings({
  required List<PickedMaterial> picked,
  required List<SemanticUnit> units,
  SubtitleStyle? subtitle,
  List<UnitReplacement> replacements = const [],
}) {
  final out = <String>[];
  // 哪几段成片里没有台词字幕。**它决定了下面那条烧字警告有多严重**：
  // 会烧字幕的段落是两层字打架、片子废；不烧的只是「片子里放着别人的
  // 文案」——不算废，但也不能交
  if (subtitleGapNotice(replacements) case final gap?) out.add(gap);
  if (burnedTextSummary([
        for (final m in picked) (label: '素材 ${m.id}', material: m),
      ])
      case final warn?) {
    out.add('$warn\n（不拦，照常导出——要不要换素材是你的判断）');
    // **三条信息凑齐才是完整的一句话**：素材烧着字 + 当前字幕样式盖不住
    // + 有能盖住的样式。软件手里同时握着这三条，一度什么都没说——
    // 查过、存了、还写了说明书，就是没在最后一道门上用
    final everyUnitWhole = replacements.isNotEmpty &&
        subtitleCoverage(replacements).unitsWith.isEmpty;
    // 整条片子都不烧台词字幕时就别提「盖不住」了——没有第二层字要盖
    if (subtitle != null && !_covers(subtitle.preset) && !everyUnitWhole) {
      out.add('当前字幕样式是 ${subtitle.preset.name}（白字黑描边），'
          '**盖不住素材自带的字**——原字幕会从描边缝里透出来，'
          '成片上两行字打架。换成 whiteBox（半透明黑底条）或 blurBox'
          '（毛玻璃）能盖住：ishkafel subtitle <任务> --preset whiteBox。'
          '但底条按新字幕的文本框算宽窄，原字幕更长或位置更高时仍然盖不全，'
          '那种素材只能换掉');
    }
  }
  if (brandConflictNotice(picked) ??
      brandMismatchNotice(picked: picked, sourceBrand: sourceBrandOf(units))
      case final warn?) {
    out.add('$warn\n（不拦，照常导出）');
  }
  // 「没看成」和「没问题」是两回事：不说的话，一批根本没查过的素材
  // 看起来和一批查过且干净的一模一样
  final unchecked = picked.where((m) => !m.burnedTextChecked).length;
  if (unchecked > 0) {
    out.add('有 $unchecked 条素材的画面没看成（多半是还没落到本地，'
        '或这台机器没配 AI 凭据）——**没看成不等于没问题**，'
        '这几条烧没烧字、露的是谁家产品都不知道。照常导出');
  }
  return List.unmodifiable(out);
}


/// 这个字幕样式盖不盖得住素材自带的烧录字。
///
/// 白字黑描边只有一圈描边，底下的字会从缝里透出来；带底条的（半透明黑底、
/// 毛玻璃）才挡得住。**这不是绝对的**——底条按新字幕的文本框算宽窄，
/// 原字幕更长或位置更高时照样盖不全，所以烧字本身仍然要报。
bool _covers(SubtitlePreset preset) => switch (preset) {
      SubtitlePreset.whiteBox || SubtitlePreset.blurBox => true,
      _ => false,
    };

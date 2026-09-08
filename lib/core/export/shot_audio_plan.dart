import '../audio/material_audio.dart';
import '../audio/vocal_separator.dart';
import '../models/semantic_unit.dart';
import 'composed_timeline.dart';
import 'export_plan.dart';
import 'speed_fit.dart';

/// 从一条导出组合里挑出「要保留素材原声」的那几镜，算好它们的声音参数。
///
/// 参数必须和画面那一段用的**完全一致**——同一条素材、同一个截取起点、
/// 同一个变速倍率（都问 [SpeedFit.effectiveFactor]）。差一点，声音和画面
/// 就越走越偏：画面在喷第二下了，声音还停在第一下，而且哪儿都不报错。
///
/// 只管**视觉镜头替换**这一层。整体替换那一层的声音本来就来自素材
/// （见 `AudioTrackBuilder` 的 `wholeAudio`），不走这里。
Future<List<ShotMaterialAudio>> planShotMaterialAudio({
  required List<SemanticUnit> units,
  required List<ExportSegment> segments,
  required MaterialAudioSetting taskDefault,
  required ComposedTimeline timeline,
  required Future<String> Function(int materialId) resolveMaterial,
  required Future<int?> Function(String path) probe,

  /// 把素材分成人声/背景两路。返回 null = 分不了（没装工具或失败）。
  /// 选了「人声」「背景声」而分不了时**直接抛**，见下面
  Future<SeparatedAudio?> Function(String materialPath)? separate,
}) async {
  final out = <ShotMaterialAudio>[];
  for (final segment in segments) {
    final shotIndex = segment.shotIndex;
    final candidateId = segment.candidateId;
    // 没换素材的镜头没有「素材的声音」可言；整体替换不走这条路
    if (shotIndex == null || candidateId == null) continue;
    if (segment.unitIndex >= units.length) continue;
    final unit = units[segment.unitIndex];
    if (shotIndex >= unit.shots.length) continue;

    final shot = unit.shots[shotIndex];
    final setting = resolveMaterialAudio(
      taskDefault: taskDefault,
      shotMode: shot.materialAudioMode,
      shotVolume: shot.materialAudioVolume,
    );
    if (!setting.mode.audible) continue;

    final path = await resolveMaterial(candidateId);
    final source = await _sourceFor(setting.mode, path, separate,
        where: 'U${segment.unitIndex + 1} 的 S${shotIndex + 1}');
    final candidateMs = await probe(path);
    out.add(ShotMaterialAudio(
      path: source,
      speedFactor: SpeedFit.effectiveFactor(
        candidateMs: candidateMs,
        slotMs: segment.durationMs,
        trimStartMs: segment.trimStartMs,
      ),
      trimStartMs: segment.trimStartMs,
      volume: setting.volume,
      // 镜头替换是变速对齐原坑位、时长不变，所以这个单元在成片里的长度
      // 就是它的原片长度——镜头在单元内的偏移原样搬过来即可
      composedStartMs:
          timeline.startOf(segment.unitIndex) + (segment.startMs - unit.startMs),
      durationMs: segment.durationMs,
    ));
  }
  return out;
}

/// 这一档该放哪个文件。
///
/// **分不出来就直接失败，绝不悄悄退回原声**：人是特意选了「背景声」的
/// （素材自己带口播，放原声等于两个人同时讲话）。悄悄换一路声音进成片，
/// 他要把片子导出来听一遍才可能发现——而那时已经交付出去了。
Future<String> _sourceFor(
  MaterialAudioMode mode,
  String materialPath,
  Future<SeparatedAudio?> Function(String)? separate, {
  required String where,
}) async {
  if (!mode.needsSeparation) return materialPath;
  if (separate == null) {
    throw StateError('$where 选了「${mode.label}」，但这次没有分离能力可用。'
        '去「设置 → 运行环境」装好人声分离工具，或把它改成「原声」/「不播放」');
  }
  final stems = await separate(materialPath);
  if (stems == null) {
    throw StateError('$where 选了「${mode.label}」，但这条素材分离失败。'
        '重试一次，或把它改成「原声」/「不播放」——'
        '不能拿另一路声音顶上，那样成片里的声音就不是你选的那个');
  }
  return mode == MaterialAudioMode.vocals
      ? stems.vocalsPath
      : stems.backgroundPath;
}

import '../core/export/subtitle_coverage.dart';
import '../core/models/renew_task.dart';
import '../core/models/semantic_unit.dart';
import '../core/replacement/replacement_plan.dart';

/// 任务的 JSON 视图——**给事实，不给结论**。
///
/// 每段多长、台词是什么、打了哪些标签、哪些镜头挑过素材，都如实摆出来；
/// 「该挑哪个」是调用方的判断（见 spec 第一节：软件提供事实与保护，
/// skill 提供方法论）。
///
/// `analyzed` 与 `units: null` 是两件事：还没分析完就是 null，**不能拿空数组
/// 冒充**「分析完了但没有单元」——调用方据此决定是等着还是往下走。
Map<String, dynamic> taskToJson(RenewTask task) {
  final units = task.units;
  return {
    'id': task.id,
    // 人对 Agent 说的是「#12」这种短编号；回传出去，Agent 复述时才对得上
    'seq': task.seq,
    'name': task.name,
    'status': task.status.name,
    // 这条任务属于哪条线。**ui new-task 给了，这里也要给**——
    // 不然事后想确认只能看 sourcePath 是不是 null 反推，
    // 或者故意跑 script show 看它报不报错
    'kind': task.script != null
        ? 'script'
        : (task.sourcePath == null ? 'blank' : 'replace'),
    'sourcePath': task.sourcePath,
    'durationMs': task.videoInfo?.duration.inMilliseconds,
    'fps': task.videoInfo?.fps,
    'analyzed': units != null,
    // 分析出错时把原因带出来：调用方要能分辨「还在跑」和「跑挂了」
    'analysisError': task.analysisError,
    'units': units == null ? null : [for (final u in units) _unitToJson(u)],
    // 替换现状（主流程唯一真相）：apply plans 投影进来、审核剔除也落这里。
    // Agent 提交后靠它验证生效、审核后靠它看剔了什么——没有这块就只能盲跑
    'replacements': task.replacements == null
        ? null
        : [
            for (var i = 0; i < task.replacements!.length; i++)
              _replacementToJson(i, task.replacements![i]),
          ],
    // 已选素材的时长。**取段靠它**：20 秒的素材塞进 0.5 秒的坑位，
    // 得先知道它是 20 秒才知道该截一段而不是压成 40 倍快放。
    // 不报出来的话，Agent 没法确认取段到底生没生效，只能盲猜
    'pickedMaterials': {
      'count': task.pickedMaterials.length,
      // **「没查过」和「这个版本没这功能」长得一模一样**——都是键不存在。
      // 给个汇总才分得开：拿到一份没有 burnedText 的输出时，
      // 到底该不该信任它「画面干净」
      'frameChecked':
          task.pickedMaterials.where((m) => m.burnedTextChecked).length,
      'frameUnchecked':
          task.pickedMaterials.where((m) => !m.burnedTextChecked).length,
      'withDuration':
          task.pickedMaterials.where((m) => (m.durationMs ?? 0) > 0).length,
      'items': [
        for (final m in task.pickedMaterials)
          {
            'id': m.id,
            'name': m.name,
            // 这条素材原本在说什么 / 画面拍的是什么。Agent 要判断
            // 「这一条到底合不合适」，光有 id 和名字判不出来
            if (m.voiceover.isNotEmpty) 'voiceover': m.voiceover,
            if (m.sceneDescription.isNotEmpty)
              'sceneDescription': m.sceneDescription,
            'durationMs': m.durationMs,
            // 画面上烧着的字。**没查过时整个键不出现**——空数组会被读成
            // 「画面干净」，而那正是把一条会毁掉整片的素材静默放行
            if (m.burnedText != null) 'burnedText': m.burnedText,
            // 画面里露出的产品是谁家的。产品露出镜头不能跨品牌换
            if (m.productBrand != null) 'productBrand': m.productBrand,
            // 上面两条是看了几帧得出的。1 帧看不全产品露出，
            // 3 帧才算看全——Agent 据此判断这个结论有多硬
            if (m.framesSeen != null) 'framesSeen': m.framesSeen,
          },
      ],
    },
    // 成片里哪几段会有台词字幕。**两种替换模式在这件事上不一样**，
    // 而这个差别此前在界面上和命令行里都看不见：镜头替换会把字幕重渲上去，
    // 整体替换原样接上、和原坑位对不齐，那一段就没有台词字幕
    if (task.replacements case final r? when r.isNotEmpty)
      'subtitleCoverage': {
        'unitsWith': subtitleCoverage(r).unitsWith,
        'unitsWithout': subtitleCoverage(r).unitsWithout,
        'note': ?subtitleGapNotice(r),
      },
    'exports': [
      for (final e in task.exports)
        {
          'at': e.at.toIso8601String(),
          'total': e.total,
          'succeeded': e.succeeded,
          'outputDir': e.outputDir,
        },
    ],
  };
}

Map<String, dynamic> _unitToJson(SemanticUnit unit) => {
      'index': unit.index,
      'startMs': unit.startMs,
      'endMs': unit.endMs,
      'durationMs': unit.endMs - unit.startMs,
      'transcript': unit.transcript,
      'tags': unit.tags,
      'shots': [
        for (var i = 0; i < unit.shots.length; i++)
          {
            'index': i,
            'startMs': unit.shots[i].startMs,
            'endMs': unit.shots[i].endMs,
            'durationMs': unit.shots[i].endMs - unit.shots[i].startMs,
            'description': unit.shots[i].description,
            // 这一镜露的是谁家产品——**「本片是什么品牌」的唯一可靠来源**。
            // 判断候选对不对得上本片，参照只能从这里来
            if (unit.shots[i].productBrand != null)
              'productBrand': unit.shots[i].productBrand,
            'tags': unit.shots[i].tags,
          },
      ],
    };

Map<String, dynamic> _replacementToJson(int index, UnitReplacement r) => {
      'unit': index,
      'mode': r.mode.name,
      if (r.mode == ReplacementMode.whole) 'materials': r.wholeCandidateIds,
      if (r.mode == ReplacementMode.perShot)
        'shots': {
          for (final e in r.shotCandidateIds.entries) '${e.key}': e.value,
        },
    };

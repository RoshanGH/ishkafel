import '../../core/export/speed_fit.dart';
import '../../core/ffmpeg/process_runner.dart' show FfmpegException;
import '../../core/log/app_log.dart';
import '../../core/miaoa/miaoa_content_service.dart';
import '../../core/miaoa/miaoa_tag_service.dart' show MiaoaException;
import '../../core/export/export_plan.dart';
import '../../core/replacement/replacement_plan.dart';

/// 阶段②「替换选材」的全部用户可见文案（纯函数，无 Flutter 依赖）。
///
/// 单独成文件的理由：这些提示是产品的一部分（尤其是几条边界的引导语），
/// 需要能被单测逐条钉住；混在 widget 里只能靠 `find.textContaining` 间接
/// 断言，改一个字就得改一堆 widget 测试。
///
/// 口径遵循 `docs/术语表.md`：台词语义单元 / 视觉镜头 / 标签组 / 候选素材 /
/// 矩阵导出。

/// 状态栏最多点名几个单元：再多一行放不下，摊开等于什么都没说清
const int _maxFactorsInline = 6;

/// 组合数状态栏：`当前组合 12 条，全部导出 · U1 2 种 × U3 6 种`
/// 或 `当前组合 121 条，导出其中 100 条`
///
/// **只点名真的挑了素材的那几个单元**。原来是把每个单元的数一字排开，
/// 于是四个单元里挑了一个就写成「当前组合 1 × 2 × 1 × 1 = 2 条」——
/// 那三个 1 不带任何信息，还让人以为软件在说什么算式（2026-09-09 设计走查）。
///
/// **候选选多了不是错误**——人本来就该随便挑，挑完由软件挑出 100 条来导。
/// 这里只负责如实说清「导出来的是不是全部」。
String combinationSummaryText(ReplacementPlan plan) {
  // 每一种排法都撞同一条素材时，「当前组合 2 条」是个假数——
  // 那 2 条一条都排不出来（2026-09-10 真机走查：状态栏说 2 条、
  // 导出对话框说 0 条）
  if (ExportPlanner.unavoidableClashes(plan.units).isNotEmpty) {
    return '排不出成片：有素材同时用在两个位置上，换掉其中一处才导得出来';
  }
  final over = plan.exceedsLimit;
  final count =
      plan.overflowsPreciseCount ? '很多' : '${plan.preciseCombinationCount} 条';
  final tail = over ? '导出其中 ${ReplacementPlan.maxCombinations} 条' : '全部导出';
  final contributors = [
    for (var i = 0; i < plan.units.length; i++)
      if (plan.units[i].factor > 1) 'U${i + 1} ${plan.units[i].factor} 种',
  ];
  if (contributors.isEmpty) {
    return '还没挑替换素材，现在就原片这 1 条';
  }
  if (contributors.length > _maxFactorsInline) {
    return '当前组合 $count，$tail';
  }
  return '当前组合 $count，$tail · ${contributors.join(' × ')}';
}

/// 「进入矩阵导出」被禁用的原因；可以导出时返回 null。
///
/// **组合数多不在此列**：候选选多了是常态，软件按规则挑出 100 条导就是了，
/// 让人回去一个个删候选是把软件该干的活推给人（真机上撞到过：
/// 底部横幅写「无法导出，请先减少 U2 选中的候选素材」，而 U2 的因子是
/// 四百多万——那句话等于让人从头再挑一遍）。
/// [pendingMedia] 是已选但**本体还没落到本地**的素材条数，[failedMedia] 是
/// 其中彻底下不下来的。素材没齐就导，成片里会缺画面——用户设置好的东西
/// 出了错就该直接失败，而不是导出一批半成品（见 docs/2026-08-07-四种替换的
/// 导出规格.md「导出兜底原则」）。
String? exportBlockedReason(
  ReplacementPlan plan, {
  int pendingMedia = 0,
  int failedMedia = 0,
}) {
  // **一条都排不出来时，别让人点进去才发现。**
  //
  // 一条成片里不允许同一条素材出现两次；两个位置都只挑了同一条时，
  // 每一种排法都会被丢掉，结果是 0 条。2026-09-10 真机走查里三个地方
  // 各说各的：底部状态栏说「2 条」、导出对话框说「0 条」、
  // 而「进入矩阵导出」照样可以点。
  final clashes = ExportPlanner.unavoidableClashes(plan.units);
  if (clashes.isNotEmpty) {
    final where = [
      for (final e in clashes.entries) '素材 ${e.key} 同时用在 ${e.value.join('、')}',
    ];
    return '排不出成片：一条成片里不能出现同一条素材两次，而现在每一种排法'
        '都会撞上。${where.join('；')}。在其中一处换一条素材就好了';
  }
  if (failedMedia > 0) {
    return '有 $failedMedia 条已选素材没能存到本地，导出会缺画面。'
        '请在「替换素材」的已选托盘上点 ↻ 重试，或换一条素材';
  }
  if (pendingMedia > 0) {
    return '正在把 $pendingMedia 条已选素材存到本地，存完就能导出'
        '——存到本地之后，素材库那边被删也不影响这条任务';
  }
  return null;
}

/// 一条替换都没设置时的提醒。不阻断导出——用户可能就是想先导一条原片，
/// 但必须如实说明导出结果是什么，不能让人以为软件没生效。
const String emptyPlanNotice = '还没有为任何台词语义单元设置替换，现在导出的成片与原片相同';

/// 矩阵导出（阶段③）尚未开放的说明。入口按钮要在，但不能是一个点不动
/// 又没有任何解释的死按钮。
const String stage3UnavailableNotice = '矩阵导出（阶段③）尚未开放，本期只能保存替换方案；'
    '方案已随任务保存，功能上线后可直接继续';

/// 检索返回 0 条时的引导。
///
/// 「素材库里确实没有」与「这个镜头压根没打上标签」是两种完全不同的处境：
/// 前者要放宽条件或换检索方式，后者要回去补打标签——给同一句话等于没给。
String emptyResultGuidance({
  required CandidateSearchMode mode,
  required int queryTagCount,
  bool perShot = true,
}) {
  switch (mode) {
    case CandidateSearchMode.tag:
      if (queryTagCount == 0) {
        return '这个${perShot ? '视觉镜头' : '台词语义单元'}还没有打上标签，'
            '按标签检索没有可用的检索键。可以回到时间线上为它补上标签';
      }
      return '这个项目里没有带这些标签的候选素材。可以换一个项目，'
          '或回去调整这一层的标签';
    case CandidateSearchMode.description:
      return '素材库里没有画面描述相近的候选素材。换个说法描述这段画面，'
          '或改用「首帧搜图」按画面找';
    case CandidateSearchMode.image:
      return '素材库里没有与这一帧相似的候选素材。可以换一帧作为查询帧，'
          '或改用「标签」「画面描述」再找一遍';
  }
}

/// 标签检索为什么不可用；可用时返回 null。
///
/// 两种不可用的原因要分开说：任务层面没选标签组（新建任务时就定了，改不了）
/// 与这一个镜头没打上标签（换个镜头就能用）。
String? tagSearchDisabledReason({
  required bool hasShotTagGroup,
  required int queryTagCount,
  bool perShot = true,
}) {
  final layer = perShot ? '视觉镜头' : '台词语义单元';
  if (!hasShotTagGroup) {
    return '这条任务没有为$layer选择标签组，这一层没有打标，因此无法按标签检索。'
        '可在「标签组设置」里补上';
  }
  if (queryTagCount == 0) {
    return '这个$layer没有标签，无法按标签检索';
  }
  return null;
}

/// 候选面板上展示的「标签检索为什么不可用」完整说明；可用时返回 null。
///
/// 两种处境的下一步完全不同：任务层面没选标签组是新建时就定死的（只能换
/// 检索方式），而单个镜头没打上标签是可以回切分阶段补的——所以后者复用
/// [emptyResultGuidance] 那句更完整的引导。
String? tagSearchUnavailableText({
  required bool hasShotTagGroup,
  required int queryTagCount,
  bool perShot = true,
}) {
  if (!hasShotTagGroup) {
    return tagSearchDisabledReason(
        hasShotTagGroup: false, queryTagCount: queryTagCount, perShot: perShot);
  }
  if (queryTagCount == 0) {
    return emptyResultGuidance(
        mode: CandidateSearchMode.tag, queryTagCount: 0, perShot: perShot);
  }
  return null;
}

/// 首帧搜图暂不可用的原因。
///
/// miaoa 的 `--like-image` 收的是**素材库里的 OSS key**，而原片这一帧只存在
/// 于本地磁盘上；要用它检索必须先把帧上传到素材库，这条链路本期没有接通。
/// 与其留一个点了没反应的按钮，不如把卡在哪一步说清楚。
const String imageSearchUnavailableReason = '首帧搜图需要先把这一帧上传到素材库换取检索键，'
    '该链路尚未接通。请先用「标签」或「画面描述」检索';

/// 检索失败提示。
///
/// [MiaoaContentService] 与子进程封装已经把 401/403/未安装/超时翻译成了可照做的
/// 中文，这里**原样透出**：再包一层「未知错误：」只会把一句能照做的话变成
/// 一句吓人的话。只有真正陌生的异常才落到通用兜底（原文进日志，不给用户看）。
String describeSearchFailure(Object error) {
  if (error is MiaoaException) return error.message;
  if (error is FfmpegException) return error.message;
  AppLog.warn('候选素材检索出现未预期异常：$error');
  return '素材库检索失败，请稍后重试';
}

/// 候选时长：`6.8s`
String candidateDurationText(int durationMs) =>
    '${(durationMs / 1000).toStringAsFixed(1)}s';

/// 时长差徽标文案；探测未完成（[candidateMs] 为 null）或目标时长非法时返回
/// null——候选卡据此**不显示徽标**，而不是显示一个 0 冒充出来的假数据。
String? durationDeltaText({required int? candidateMs, required int targetMs}) {
  if (candidateMs == null || targetMs <= 0) return null;
  final deltaSec = (candidateMs - targetMs) / 1000;
  if (deltaSec.abs() < 0.05) return null;
  final sign = deltaSec > 0 ? '+' : '−'; // U+2212 真减号，与连字符区分
  return '$sign${deltaSec.abs().toStringAsFixed(1)}';
}

/// 选中这条素材之后，这一镜会放多快。
///
/// **视觉镜头替换一律整条变速铺满原镜头时长**：素材比坑位长多少倍，成片里
/// 就快放多少倍。这个代价要在挑的时候看得见——真机上一条 34 镜的片子里，
/// 102 条候选有 74 条比坑位长 3 倍以上，不标出来人挑完根本不知道自己选了
/// 一串快进。
///
/// 探不到时长（[candidateMs] 为 null）或坑位非法时返回 null——不拿一个
/// 猜的倍率冒充。几乎不变速（±2%）时也返回 null：「1.01×」只是噪音。
String? candidateSpeedText({required int? candidateMs, required int slotMs}) {
  if (candidateMs == null || candidateMs <= 0 || slotMs <= 0) return null;
  final factor = SpeedFit.factorFor(candidateMs: candidateMs, slotMs: slotMs);
  if ((factor - 1).abs() <= 0.02) return null;
  return '${factor.toStringAsFixed(factor >= 10 ? 0 : 1)}×';
}

/// 这个倍率算不算过分——决定倍速徽标画成什么颜色。
///
/// 1.25 倍以内人眼看不出来；到 2 倍已经是明显的快进/慢放；再往上就是
/// 一道闪光了，得红着标出来。
SpeedSeverity candidateSpeedSeverity(
    {required int? candidateMs, required int slotMs}) {
  if (candidateMs == null || candidateMs <= 0 || slotMs <= 0) {
    return SpeedSeverity.fine;
  }
  final factor = SpeedFit.factorFor(candidateMs: candidateMs, slotMs: slotMs);
  final away = factor >= 1 ? factor : 1 / factor;
  if (away <= 1.25) return SpeedSeverity.fine;
  if (away <= 2) return SpeedSeverity.noticeable;
  return SpeedSeverity.severe;
}

enum SpeedSeverity { fine, noticeable, severe }

/// 候选规格还在探测时的占位（不能留空白，用户会以为卡住了）
const String probingSpecLabel = '探测中';

/// 右栏底部这一行：`S2 已选 3 / 18 条 · U3 能排出 6 种（S1 挑 2 条 × S2 挑 3 条）`
///
/// **不说「因子」**：那是算组合数时的内部说法，界面上人要知道的是
/// 「这一段能排出几种画面」。也**不摊开全是 1 的算式**——13 个镜头一个都
/// 没挑时，原来会写成「因子 = 1 × 1 × 1 × 1 × 1 × 1 × 1 × 1 × 1 × 1 × 1 ×
/// 1 × 1 = 1」，占满一行却一个字的信息都没有（2026-09-09 设计走查）。
String selectionSummaryText({
  required int unitIndex,
  required int? shotIndex,
  required int selectedCount,
  required int totalCount,
  required UnitReplacement replacement,
  required int shotCount,
}) {
  final unitLabel = 'U${unitIndex + 1}';
  switch (replacement.mode) {
    case ReplacementMode.keepOriginal:
      return '$unitLabel 保留原片，这一段不参与组合';
    case ReplacementMode.whole:
      return '$unitLabel 已选 $selectedCount / $totalCount 条 · '
          '$unitLabel 能排出 ${replacement.factor} 种';
    case ReplacementMode.perShot:
      final scope = shotIndex == null ? unitLabel : 'S${shotIndex + 1}';
      final head = '$scope 已选 $selectedCount / $totalCount 条';
      // 只列**真的挑了素材**的那几镜。按镜头顺序排，人才对得上是哪一镜
      // 贡献了哪个数
      final contributors = [
        for (var i = 0; i < shotCount; i++)
          if ((replacement.shotCandidateIds[i] ?? const <int>[]).isNotEmpty)
            'S${i + 1} 挑 ${replacement.shotCandidateIds[i]!.length} 条',
      ];
      if (contributors.isEmpty) {
        return '$head · $unitLabel 还没挑素材，这一段照原片播';
      }
      final detail =
          contributors.length == 1 ? '' : '（${contributors.join(' × ')}）';
      return '$head · $unitLabel 能排出 ${replacement.factor} 种$detail';
  }
}

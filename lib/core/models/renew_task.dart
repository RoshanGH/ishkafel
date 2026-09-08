import 'package:collection/collection.dart';
import '../analysis/providers.dart';
import '../log/app_log.dart';
import '../ai/ai_usage.dart';
import '../audio/bgm_plan.dart';
import '../audio/material_audio.dart';
import '../subtitle/subtitle_style.dart';
import '../subtitle/subtitle_track.dart';
import '../audio/voice_plan.dart';
import '../replacement/picked_material.dart';
import '../script/script_doc.dart';
import '../replacement/replacement_plan.dart';
import 'project_ref.dart';
import 'tag_group_ref.dart';
import 'video_info.dart';
import 'export_record.dart';
import 'semantic_unit.dart';

/// 项目状态：**分析中 → 可编辑**。就这两个，没有「完成」。
///
/// 这个产品的对象是一条原片放在那儿、反复出不同组合：今天挑两个导出去，
/// 明天换两个再导。**项目本身没有终态**，有始有终的是每一次导出
/// （见 [ExportRecord]）。用户原话：「编辑中这个状态有没有结束那一刻呢？
/// 如果没有的话，那就不用写出来了吧？」
///
/// 曾经有 `exported`（已导出），但**代码里从来没有一处把它设上过**——
/// 于是「编辑中」永远不会结束、「已完成」筛选永远是空的、只读回看那一整套
/// 逻辑是死代码。老存档里的 `exported` 由 [parseStatus] 落到 [ready]。
///
/// 也曾有 awaitingCut（待切分确认）与 picking（选材中），对应「先确认切分、
/// 再进入替换选材」两个页面；两个页面合并成一个工作台后它们之间已无行为
/// 差异，同样由 [parseStatus] 兜底。
enum RenewTaskStatus { analyzing, ready }

/// 有原片的任务实体（不可变）
class RenewTask {
  final String id;
  final String name;

  /// 人念得出口的短编号（#1、#2……），建任务时分配、终生不变。
  ///
  /// [id] 是机器身份（长随机串），没法在对话里指代——「把 #12 导出一下」
  /// 才是人跟 Agent 沟通的方式；任务名冗长且可能重复，顶不了这个用。
  /// 旧任务没有此字段，加载时按创建时间补号（见 ensureTaskSeqs）。
  final int? seq;
  /// 原片路径。**为 null 表示这是一条空白任务**——没有原片，分子和标签
  /// 手动填，只靠标签检索素材拼片（见 docs/superpowers/specs/
  /// 2026-08-12-blank-task-design.md）。
  ///
  /// 用可空而不是空串：空串是个谎，而且不会有任何地方报错。可空之后编译器
  /// 会把每一处假设「原片一定在」的地方指出来，逐个决策。
  final String? sourcePath;
  final String? miaoaVideoId;

  /// 空白任务：没有原片。分子手动添加、标签手动填，每个分子都走整体替换
  bool get isBlank => sourcePath == null && script == null;

  /// 脚本成片任务：以脚本行为根（「脚本即成片」），工作页是编导台。
  /// 与空白任务同样没有原片，靠 [script] 判别
  bool get isScript => script != null;

  /// 脚本成片的脚本文档；非脚本任务为 null
  final ScriptDoc? script;
  final VideoInfo? videoInfo;
  final String? coverPath;
  final RenewTaskStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<SemanticUnit>? units;
  final List<AsrSentence>? asrSentences;

  /// 台词语义单元打标所用的 miaoa 标签组（受控词表的来源）。
  ///
  /// 可以选多个：一个单元本来就该同时有几个维度的标签，只能选一个组等于
  /// 只能打一个维度。多个组的标签合并成一份受控词表。空表示该层不打标。
  final List<TagGroupRef> unitTagGroups;

  /// 视觉镜头打标所用的 miaoa 标签组（同样可多选）；空表示该层不打标
  final List<TagGroupRef> shotTagGroups;

  /// 这条任务在哪个 miaoa 项目下找素材；null 表示不限项目（我的全部项目）。
  ///
  /// 素材库里四万多条分镜横跨几十个项目，不限项目搜出来的大多不是这条片子
  /// 能用的。放在标签组旁边一起设：两者都是「这条任务上哪儿找素材」这件事。
  final ProjectRef? project;

  /// 分离出来的纯人声（口播）轨与纯背景音轨。分析时产出一次，之后一直用。
  ///
  /// 为什么要留着：换配乐时得把原片自带的背景音去掉，只留口播——不分离的话
  /// 新配乐只能叠在原声上，两首曲子一起响。为 null 表示没分离成功（机器上
  /// 没装分离工具，或那一步失败了），此时只能沿用原混音。
  final String? vocalsPath;
  final String? backgroundPath;

  /// 台词语义单元这一层的打标约束（用户写的提示词），空串表示没写。
  ///
  /// **一层一条，不是一组一条**：一层选四个组时，四个组是同一次打标里的四个
  /// 维度，用户想约束的是「这一层要怎么判」这件事本身；每个组各挂一条约束，
  /// 界面上会冒出四个输入框，用户得把同一句话抄四遍。
  ///
  /// 存在**任务**上而不是全局：换一条片子口径就可能变。新建任务时由上一条
  /// 任务复制一份带出来，免得反复贴。
  final String unitTagPrompt;

  /// 视觉镜头这一层的打标约束；空串表示没写
  final String shotTagPrompt;

  /// 兼容读法：只关心「有没有选」或「第一个是哪个」的地方继续用它
  TagGroupRef? get unitTagGroup =>
      unitTagGroups.isEmpty ? null : unitTagGroups.first;
  TagGroupRef? get shotTagGroup =>
      shotTagGroups.isEmpty ? null : shotTagGroups.first;

  /// 最近一次分析失败的原因摘要（已按长度截断）；为 null 表示未失败或已重试清除
  final String? analysisError;

  /// 阶段②「替换选材」的方案，按 [units] 的下标一一对齐；
  /// null 表示这条任务还没进过阶段②（旧任务读出来就是 null）。
  ///
  /// 长度未必与 [units] 相等：切分被改动后单元数会变，读取方（阶段②页面）
  /// 负责按当前单元数补位/截断，模型层不擅自纠正——擅自补位会把「用户到底
  /// 选过没有」这个事实抹掉。
  final List<UnitReplacement>? replacements;

  /// 每一次导出的记录（时间倒序由读取方决定，这里按发生顺序追加）。
  /// 项目没有终态，**导出才是那件有始有终的事**——见 [ExportRecord]
  final List<ExportRecord> exports;

  /// 已挑中的素材，落到盘上的那一份（按 [replacements] 里出现过的候选 id
  /// 收敛，不再被引用的会被清掉）。见 [PickedMaterial]。
  ///
  /// [replacements] 里只有一串 id，光凭它画不出「我选的是哪三条」——
  /// 候选卡只有当前这一页的检索结果，翻页/换检索方式/换项目组/重开 app
  /// 之后一个勾都看不见。
  final List<PickedMaterial> pickedMaterials;

  /// 配乐方案：一段 BGM 铺在连续的一串视觉镜头上（可跨台词语义单元）。
  /// 见 [BgmPlan]。
  final BgmPlan bgm;

  /// 换音色方案：哪几个台词语义单元换成哪个音色。见 [VoicePlan]。
  final VoicePlan voices;

  /// 首次「能进去干活」之前，人**真的**等了多少毫秒。
  ///
  /// 从导入后开始分析算到切分就绪（能进编辑页）那一刻，不是分析全部跑完
  /// ——打标在后台补，用户那时已经在时间线上操作了。只记第一次，之后重打标
  /// 不再改它。
  final int? firstReadyMs;

  /// 烧进成片的字幕长什么样。
  ///
  /// **两个预设是用来遮挡的**：素材自带烧录字幕时（库里不少见，而且画面
  /// 描述里一个字都看不出来），默认的白字黑描边盖不住，原字幕会从描边缝里
  /// 透出来，成片上就是两行字打架。`whiteBox`（半透明黑底条）和
  /// `blurBox`（毛玻璃）能盖住。
  ///
  /// 以前这条线写死用标准样式——人和 Agent 都没得选，遇到这种素材无解。
  final SubtitleStyle subtitle;

  /// **手改过的**字幕（只有被替换的视觉镜头才会进来）。没改过的坑位
  /// 导出时照 ASR 现算——见 [SubtitleTrack]。
  ///
  /// 「字幕是字幕，台词是台词」：改它不动 [SemanticUnit.transcript]
  final SubtitleTrack subtitleTrack;

  /// 「保留素材原声」的**全片打底**设置。单个视觉镜头可以覆盖它
  /// （见 [Shot.keepMaterialAudio]）。默认关——升级一版不该让存量任务
  /// 导出来的片子突然多出一层声音
  final MaterialAudioSetting materialAudio;

  /// 这个任务累计花掉的 AI 用量。**会一直涨**：在工作台里每重打一次标、
  /// 每复核一次切点都记进来。见 [AiUsage]。
  final AiUsage aiUsage;

  RenewTask({
    required this.id,
    required this.name,
    this.sourcePath,
    this.script,
    this.seq,
    this.miaoaVideoId,
    this.videoInfo,
    this.coverPath,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.units,
    this.asrSentences,
    List<TagGroupRef> unitTagGroups = const [],
    List<TagGroupRef> shotTagGroups = const [],
    this.project,
    this.vocalsPath,
    this.backgroundPath,
    this.unitTagPrompt = '',
    this.shotTagPrompt = '',
    this.analysisError,
    List<UnitReplacement>? replacements,
    List<PickedMaterial> pickedMaterials = const [],
    List<ExportRecord> exports = const [],
    this.bgm = BgmPlan.empty,
    this.voices = VoicePlan.empty,
    this.firstReadyMs,
    this.aiUsage = AiUsage.empty,
    this.subtitle = SubtitleStyle.standard,
    this.subtitleTrack = const SubtitleTrack.empty(),
    this.materialAudio = MaterialAudioSetting.off,
  })  : unitTagGroups = List.unmodifiable(unitTagGroups),
        shotTagGroups = List.unmodifiable(shotTagGroups),
        pickedMaterials = List.unmodifiable(pickedMaterials),
        exports = List.unmodifiable(exports),
        replacements =
            replacements == null ? null : List.unmodifiable(replacements);

  /// 标签组列表的宽松解析：先认新的数组字段，没有再退回旧的单个字段。
  ///
  /// 单条畸形只跳过它——为一个坏条目丢掉整条任务，用户看到的是「任务不见了」
  /// （本项目踩过这个坑）。
  static List<TagGroupRef> parseTagGroups(Object? list, Object? legacySingle) {
    if (list is List) {
      return List.unmodifiable([
        for (final e in list) ?TagGroupRef.tryFromJson(e),
      ]);
    }
    final single = TagGroupRef.tryFromJson(legacySingle);
    return single == null ? const [] : List.unmodifiable([single]);
  }

  /// 打标约束的解析。约束一度是**按组**存的（每个组的 JSON 里一个 prompt），
  /// 改成一层一条之后，旧任务里那几条不能就这么丢掉——用户写过的东西凭空
  /// 消失比字段改名难查得多。取旧数据里第一条非空的作为这一层的约束。
  static String parsePrompt(Object? current, Object? legacyGroups) {
    if (current is String) return current;
    if (legacyGroups is! List) return '';
    for (final g in legacyGroups) {
      if (g is Map && g['prompt'] is String) {
        final text = (g['prompt'] as String).trim();
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  static bool _sameGroups(List<TagGroupRef> a, List<TagGroupRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// [clearAnalysisError] 为 true 时显式清空 analysisError（重试分析时使用）；
  /// 其余可空字段沿用 units/asrSentences 的简单覆盖模式（不支持单独清空）。
  /// 技术债备注：清空可空字段目前是 per-field 布尔标志（每加一个需要清空的
  /// 字段就多一个 `clearXxx` 参数），若后续 videoInfo/coverPath 等字段也需要
  /// 支持清空，应收敛为统一的 sentinel 方案（例如用一个私有 `_unset` 哨兵对象
  /// 区分「未传参」与「显式传 null」），而不是继续堆叠布尔参数。
  RenewTask copyWith({
    String? id,
    String? name,
    int? seq,
    String? sourcePath,
    ScriptDoc? script,
    String? miaoaVideoId,
    VideoInfo? videoInfo,
    String? coverPath,
    RenewTaskStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<SemanticUnit>? units,
    List<AsrSentence>? asrSentences,
    List<TagGroupRef>? unitTagGroups,
    List<TagGroupRef>? shotTagGroups,
    ProjectRef? project,
    bool clearProject = false,
    String? vocalsPath,
    String? backgroundPath,
    String? unitTagPrompt,
    String? shotTagPrompt,
    String? analysisError,
    bool clearAnalysisError = false,
    List<UnitReplacement>? replacements,
    List<PickedMaterial>? pickedMaterials,
    List<ExportRecord>? exports,
    BgmPlan? bgm,
    VoicePlan? voices,
    int? firstReadyMs,
    AiUsage? aiUsage,
    SubtitleStyle? subtitle,
    SubtitleTrack? subtitleTrack,
    MaterialAudioSetting? materialAudio,
  }) =>
      RenewTask(
        id: id ?? this.id,
        name: name ?? this.name,
        seq: seq ?? this.seq,
        sourcePath: sourcePath ?? this.sourcePath,
        script: script ?? this.script,
        miaoaVideoId: miaoaVideoId ?? this.miaoaVideoId,
        videoInfo: videoInfo ?? this.videoInfo,
        coverPath: coverPath ?? this.coverPath,
        status: status ?? this.status,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        units: units ?? this.units,
        asrSentences: asrSentences ?? this.asrSentences,
        unitTagGroups: unitTagGroups ?? this.unitTagGroups,
        shotTagGroups: shotTagGroups ?? this.shotTagGroups,
        project: clearProject ? null : (project ?? this.project),
        vocalsPath: vocalsPath ?? this.vocalsPath,
        backgroundPath: backgroundPath ?? this.backgroundPath,
        unitTagPrompt: unitTagPrompt ?? this.unitTagPrompt,
        shotTagPrompt: shotTagPrompt ?? this.shotTagPrompt,
        // **把状态置成 ready 就等于宣布分析成功**，那一刻要连带清掉上一次的
        // 分析错误。真机上撞到过：一个 35 镜分析完、方案提交过、导出成功四次的
        // 任务，列表里挂着红色「上次分析被中断，请重新分析」——七个地方把状态
        // 置成 ready，没有一处记得清这个字段。
        // 显式传了 analysisError 的除外（那是「置成 ready 的同时记一笔错」，
        // 目前没人这么用，但语义上要让调用方说了算）。
        analysisError: clearAnalysisError
            ? null
            : analysisError ??
                (status == RenewTaskStatus.ready &&
                        this.status == RenewTaskStatus.analyzing
                    ? null
                    : this.analysisError),
        replacements: replacements ?? this.replacements,
        pickedMaterials: pickedMaterials ?? this.pickedMaterials,
        exports: exports ?? this.exports,
        bgm: bgm ?? this.bgm,
        voices: voices ?? this.voices,
        firstReadyMs: firstReadyMs ?? this.firstReadyMs,
        aiUsage: aiUsage ?? this.aiUsage,
        subtitle: subtitle ?? this.subtitle,
        subtitleTrack: subtitleTrack ?? this.subtitleTrack,
        materialAudio: materialAudio ?? this.materialAudio,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (seq != null) 'seq': seq,
        'sourcePath': sourcePath,
        if (script != null) 'script': script!.toJson(),
        'miaoaVideoId': miaoaVideoId,
        'videoInfo': videoInfo?.toJson(),
        'coverPath': coverPath,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'units': units?.map((u) => u.toJson()).toList(),
        'asrSentences': asrSentences?.map((s) => s.toJson()).toList(),
        'unitTagGroups': [for (final g in unitTagGroups) g.toJson()],
        'shotTagGroups': [for (final g in shotTagGroups) g.toJson()],
        // 旧字段一并写：本项目按「打包好的 .app 发给同事」分发，新旧版本会
        // 并存，旧版本只认单个字段，不写它任务在旧版本上就成了「没选标签组」
        'unitTagGroup': unitTagGroup?.toJson(),
        'shotTagGroup': shotTagGroup?.toJson(),
        'project': project?.toJson(),
        'vocalsPath': vocalsPath,
        'backgroundPath': backgroundPath,
        'unitTagPrompt': unitTagPrompt,
        'shotTagPrompt': shotTagPrompt,
        'analysisError': analysisError,
        'replacements': replacements?.map((r) => r.toJson()).toList(),
        'pickedMaterials': pickedMaterials.map((m) => m.toJson()).toList(),
        'exports': exports.map((e) => e.toJson()).toList(),
        'bgm': bgm.toJson(),
        'subtitle': subtitle.toJson(),
        if (!subtitleTrack.isEmpty) 'subtitleTrack': subtitleTrack.toJson(),
        'materialAudio': materialAudio.toJson(),
        'voices': voices.toJson(),
        'firstReadyMs': firstReadyMs,
        'aiUsage': aiUsage.toJson(),
      };

  factory RenewTask.fromJson(Map<String, dynamic> json) {
    // 先解出单元：配乐的老存档要靠它把镜头下标换算成单元下标
    final units = (json['units'] as List<dynamic>?)
        ?.map((e) => SemanticUnit.fromJson(e as Map<String, dynamic>))
        .toList();
    return RenewTask(
        id: json['id'] as String,
        name: json['name'] as String,
        seq: json['seq'] is num ? (json['seq'] as num).toInt() : null,
        sourcePath: json['sourcePath'] as String?,
        script: json['script'] is Map
            ? ScriptDoc.fromJson(json['script'])
            : null,
        miaoaVideoId: json['miaoaVideoId'] as String?,
        videoInfo: json['videoInfo'] == null
            ? null
            : VideoInfo.fromJson(json['videoInfo'] as Map<String, dynamic>),
        coverPath: json['coverPath'] as String?,
        status: parseStatus(json['status']),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        units: units,
        asrSentences: (json['asrSentences'] as List<dynamic>?)
            ?.map((e) => AsrSentence.fromJson(e as Map<String, dynamic>))
            .toList(),
        unitTagGroups: parseTagGroups(json['unitTagGroups'], json['unitTagGroup']),
        shotTagGroups: parseTagGroups(json['shotTagGroups'], json['shotTagGroup']),
        project: ProjectRef.tryFromJson(json['project']),
        vocalsPath: json['vocalsPath'] as String?,
        backgroundPath: json['backgroundPath'] as String?,
        unitTagPrompt:
            parsePrompt(json['unitTagPrompt'], json['unitTagGroups']),
        shotTagPrompt:
            parsePrompt(json['shotTagPrompt'], json['shotTagGroups']),
        analysisError: json['analysisError'] as String?,
        replacements: parseReplacements(json['replacements']),
        pickedMaterials: PickedMaterial.parseList(json['pickedMaterials']),
        exports: ExportRecord.parseList(json['exports']),
        // 老存档里配乐是按**镜头**记区间的，读出来后按单元换算一次
        // （见 [BgmPlan.migrateShotsToUnits]）——直接丢掉的话用户已经选好的
        // 配乐会凭空消失
        bgm: BgmPlan.fromJson(json['bgm'])
            .migrateShotsToUnits(units ?? const []),
        voices: VoicePlan.fromJson(json['voices']),
        // 老任务没有这个字段，退回标准样式
        subtitle: SubtitleStyle.fromJson(json['subtitle']),
        subtitleTrack: SubtitleTrack.fromJson(json['subtitleTrack']),
        // 存量存档没有这个字段——兜底成「关」，不能让老任务升一版就多一层声音
        materialAudio: MaterialAudioSetting.fromJson(
            json['materialAudio'] as Map<String, dynamic>?),
        firstReadyMs:
            json['firstReadyMs'] is num ? (json['firstReadyMs'] as num).toInt() : null,
        aiUsage: AiUsage.fromJson(json['aiUsage']),
      );
  }

  /// 替换方案的宽松解析：整体畸形按「没进过阶段②」（null）处理，
  /// 单条畸形降级为保留原片但**保留位置**——列表下标就是台词语义单元下标，
  /// 少一条会让后面所有单元的方案整体错位到别的单元上。
  static List<UnitReplacement>? parseReplacements(Object? raw) {
    if (raw == null) return null;
    if (raw is! List) {
      AppLog.warn('任务替换方案字段不是数组（${raw.runtimeType}），按未选材处理');
      return null;
    }
    return List.unmodifiable([
      for (final entry in raw)
        UnitReplacement.tryFromJson(entry) ?? UnitReplacement.keepOriginal(),
    ]);
  }

  /// 未知/缺失状态一律回退到 [fallbackStatus]，绝不抛异常。
  ///
  /// 抛异常的后果是整条任务在 findAll 里被跳过——用户看到的是「我的任务不见
  /// 了」。未知值通常来自更新版本写入的后续状态（如导出中），回退到只读回看
  /// 的「选材中」最保守：既能看到任务、又不会误导用户去改已流转的数据。
  static RenewTaskStatus parseStatus(Object? raw) {
    final name = raw is String ? raw : null;
    if (name == null) return fallbackStatus;
    final matched =
        RenewTaskStatus.values.firstWhereOrNull((s) => s.name == name);
    if (matched != null) return matched;
    // 老存档里的 editing / exported / awaitingCut / picking 一律落到 ready：
    // 它们现在都是同一件事——「可以进去干活」
    return fallbackStatus;
  }

  static const fallbackStatus = RenewTaskStatus.ready;

  @override
  bool operator ==(Object other) =>
      other is RenewTask &&
      other.id == id &&
      other.name == name &&
      other.sourcePath == sourcePath &&
      other.miaoaVideoId == miaoaVideoId &&
      other.videoInfo == videoInfo &&
      other.coverPath == coverPath &&
      other.status == status &&
      other.createdAt == createdAt &&
      other.updatedAt == updatedAt &&
      _sameGroups(other.unitTagGroups, unitTagGroups) &&
      _sameGroups(other.shotTagGroups, shotTagGroups) &&
      other.project == project &&
      other.unitTagPrompt == unitTagPrompt &&
      other.shotTagPrompt == shotTagPrompt &&
      other.analysisError == analysisError &&
      const DeepCollectionEquality().equals(other.units, units) &&
      const DeepCollectionEquality().equals(other.asrSentences, asrSentences) &&
      const DeepCollectionEquality().equals(other.replacements, replacements) &&
      const DeepCollectionEquality()
          .equals(other.pickedMaterials, pickedMaterials);

  @override
  int get hashCode => Object.hash(
      id,
      name,
      sourcePath,
      miaoaVideoId,
      videoInfo,
      coverPath,
      status,
      createdAt,
      updatedAt,
      Object.hashAll(unitTagGroups),
      Object.hashAll(shotTagGroups),
      project,
      unitTagPrompt,
      shotTagPrompt,
      analysisError,
      units == null ? null : Object.hashAll(units!),
      asrSentences == null ? null : Object.hashAll(asrSentences!),
      replacements == null ? null : Object.hashAll(replacements!),
      Object.hashAll(pickedMaterials));
}

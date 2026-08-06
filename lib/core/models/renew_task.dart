import 'package:collection/collection.dart';
import '../analysis/providers.dart';
import '../log/app_log.dart';
import '../ai/ai_usage.dart';
import '../audio/bgm_plan.dart';
import '../audio/voice_plan.dart';
import '../replacement/replacement_plan.dart';
import 'project_ref.dart';
import 'tag_group_ref.dart';
import 'video_info.dart';
import 'semantic_unit.dart';

/// 任务状态：分析中 / 编辑中 / 已导出
///
/// 曾经有 awaitingCut（待切分确认）与 picking（选材中）两个状态，对应
/// 「先确认切分、再进入替换选材」两个页面。两个页面合并成一个工作台后，
/// 这两个状态之间已没有任何行为差异——切分与选材在同一个页面里交替进行，
/// 再分成两个状态只会让任务卡显示一个用户无法据以行动的假区分。
/// 旧记录里的这两个名字由 [parseStatus] 兜底落到 [editing]。
enum RenewTaskStatus { analyzing, editing, exported }

/// 翻新任务实体（不可变）
class RenewTask {
  final String id;
  final String name;
  final String sourcePath;
  final String? miaoaVideoId;
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

  /// 这个任务累计花掉的 AI 用量。**会一直涨**：在工作台里每重打一次标、
  /// 每复核一次切点都记进来。见 [AiUsage]。
  final AiUsage aiUsage;

  RenewTask({
    required this.id,
    required this.name,
    required this.sourcePath,
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
    this.bgm = BgmPlan.empty,
    this.voices = VoicePlan.empty,
    this.firstReadyMs,
    this.aiUsage = AiUsage.empty,
  })  : unitTagGroups = List.unmodifiable(unitTagGroups),
        shotTagGroups = List.unmodifiable(shotTagGroups),
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
    String? sourcePath,
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
    BgmPlan? bgm,
    VoicePlan? voices,
    int? firstReadyMs,
    AiUsage? aiUsage,
  }) =>
      RenewTask(
        id: id ?? this.id,
        name: name ?? this.name,
        sourcePath: sourcePath ?? this.sourcePath,
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
        analysisError:
            clearAnalysisError ? null : (analysisError ?? this.analysisError),
        replacements: replacements ?? this.replacements,
        bgm: bgm ?? this.bgm,
        voices: voices ?? this.voices,
        firstReadyMs: firstReadyMs ?? this.firstReadyMs,
        aiUsage: aiUsage ?? this.aiUsage,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'sourcePath': sourcePath,
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
        'bgm': bgm.toJson(),
        'voices': voices.toJson(),
        'firstReadyMs': firstReadyMs,
        'aiUsage': aiUsage.toJson(),
      };

  factory RenewTask.fromJson(Map<String, dynamic> json) => RenewTask(
        id: json['id'] as String,
        name: json['name'] as String,
        sourcePath: json['sourcePath'] as String,
        miaoaVideoId: json['miaoaVideoId'] as String?,
        videoInfo: json['videoInfo'] == null
            ? null
            : VideoInfo.fromJson(json['videoInfo'] as Map<String, dynamic>),
        coverPath: json['coverPath'] as String?,
        status: parseStatus(json['status']),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        units: (json['units'] as List<dynamic>?)
            ?.map((e) => SemanticUnit.fromJson(e as Map<String, dynamic>))
            .toList(),
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
        bgm: BgmPlan.fromJson(json['bgm']),
        voices: VoicePlan.fromJson(json['voices']),
        firstReadyMs:
            json['firstReadyMs'] is num ? (json['firstReadyMs'] as num).toInt() : null,
        aiUsage: AiUsage.fromJson(json['aiUsage']),
      );

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
    AppLog.warn('任务状态「$name」无法识别，按 ${fallbackStatus.name} 处理');
    return fallbackStatus;
  }

  static const fallbackStatus = RenewTaskStatus.editing;

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
      const DeepCollectionEquality().equals(other.replacements, replacements);

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
      replacements == null ? null : Object.hashAll(replacements!));
}

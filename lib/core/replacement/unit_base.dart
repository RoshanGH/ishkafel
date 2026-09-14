import '../models/semantic_unit.dart';
import 'replacement_plan.dart';

/// 一段画面的**底片**：这一段的画面从哪张片子的哪一段来。
///
/// 切分、抽帧、打标、镜头替换全都在底片上做——「整体替换」定的是底片是谁，
/// 「镜头替换」定的是在这张底片上换掉哪一刀，两者本来就不在同一层
/// （见 `docs/superpowers/specs/2026-09-14-底片-design.md`）。
class UnitBase {
  /// 视频文件绝对路径
  final String path;

  /// 用它的第几毫秒到第几毫秒
  final int startMs;
  final int endMs;

  /// 这张底片是谁：**null = 任务原片的一段**；非 null = 挑来的素材的 id。
  ///
  /// 记 id 而不是只记路径：清理产物时要靠它判断这条素材还有没有人引用，
  /// 界面上也要靠它回指 [PickedMaterial] 画出「我选的是哪一条」
  final int? candidateId;

  const UnitBase({
    required this.path,
    required this.startMs,
    required this.endMs,
    this.candidateId,
  });

  /// 底片就是原片本身（没换过）
  bool get isOriginal => candidateId == null;

  int get durationMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      other is UnitBase &&
      other.path == path &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.candidateId == candidateId;

  @override
  int get hashCode => Object.hash(path, startMs, endMs, candidateId);

  @override
  String toString() =>
      'UnitBase($path, $startMs~$endMs, candidate=$candidateId)';
}

/// 这个单元的镜头是不是**按它自己那张底片**切出来的。
///
/// 真时，[SemanticUnit.shots] 的坐标是「`startMs` + 底片内偏移」，那一段
/// 在时间线上要一格格画、每一格可以各自换素材；假时，镜头要么是分析那次
/// 按原片切的，要么根本没有（整体替换后的一整块）。
///
/// **这条判据只有这一份**——预览、导出、时间线、属性面板全问它
bool hasOwnBaseShots(SemanticUnit unit) =>
    unit.baseCandidateId != null && unit.shots.isNotEmpty;

/// 底片是谁——**只做决策，不碰文件系统**。
///
/// 分成两层是因为两边问的时机不同：预览时素材已经落地，可以连路径一起算
/// （[baseOf]）；导出时素材还没下下来，决策却必须在那之前做出——要靠它排出
/// 这一条成片由哪些段落组成。**规则只有这一份**，两边都从这里出发。
sealed class BaseChoice {
  const BaseChoice();
}

/// 底片是任务原片的这一段
class OriginalBase extends BaseChoice {
  final int startMs;
  final int endMs;
  const OriginalBase(this.startMs, this.endMs);

  @override
  bool operator ==(Object other) =>
      other is OriginalBase && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'OriginalBase($startMs~$endMs)';
}

/// 底片是挑来的这一条素材（整体替换 = 给这一段换一张底片）
class MaterialBase extends BaseChoice {
  final int candidateId;
  const MaterialBase(this.candidateId);

  @override
  bool operator ==(Object other) =>
      other is MaterialBase && other.candidateId == candidateId;

  @override
  int get hashCode => candidateId.hashCode;

  @override
  String toString() => 'MaterialBase($candidateId)';
}

/// 这一段没有底片：原片里没有它（手加的单元），也没挑素材。
/// **不许拿黑帧或静音顶上**——垫上占位并点名，让人知道缺的是哪一段
class NoBase extends BaseChoice {
  const NoBase();

  @override
  bool operator ==(Object other) => other is NoBase;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'NoBase()';
}

/// 决定这一段的底片是谁。回退链，**顺序即优先级**：
///
/// 0. 底片被固定过（[SemanticUnit.baseCandidateId] 非空）→ 就是它
/// 1. 整体替换选了素材 → 那条素材
/// 2. 这个单元在原片上有对应的一段，且这条任务有原片 → 原片的那一段
/// 3. 否则 [NoBase]
///
/// 第 0 条为什么压过一切：这一段的镜头是**按那张底片切出来的**，换一张
/// 底片这些切点就全指错地方了。用户要换底片得走「换底片」那条路
/// （明说已挑的镜头替换会作废），不能靠改整体替换的候选悄悄换掉。
///
/// [wholeCandidateId] 是「这一条变体在这个单元上用哪张底片」。导出时同一个
/// 单元在不同变体里用不同候选，由调用方指定；不给就用 ★ 预览那条。
/// **底片固定之后它不再起作用**——固定就是固定。
BaseChoice baseChoiceOf({
  required SemanticUnit unit,
  required UnitReplacement replacement,
  int? wholeCandidateId,
  bool hasOriginal = true,
}) {
  if (unit.baseCandidateId case final pinned?) return MaterialBase(pinned);
  if (replacement.mode == ReplacementMode.whole) {
    final id = wholeCandidateId ?? replacement.wholePreviewId;
    if (id != null) return MaterialBase(id);
  }
  // **判据是「这个单元有没有原片来源」，不是「这条任务有没有原片」**——
  // 有原片的任务里也会有手加的单元，它的 startMs/endMs 只是时间线上的占位、
  // 落在原片时长之外。按后者判的话取的是一段根本不存在的时间
  // （2026-09-08 真机：「添加的台词语义单元不能正常播放」）
  if (unit.hasSource && hasOriginal) {
    return OriginalBase(unit.startMs, unit.endMs);
  }
  return const NoBase();
}

/// 求这一段的底片。**「这一段画面从哪儿来」全仓只在这里回答一次。**
///
/// 原来预览（`TrackPlanBuilder`）、导出（`ExportRunner`）、音频
/// （`AudioTrackBuilder`）各写了一遍，规则还不完全一致。
///
/// 回退链，**顺序即优先级**：
///
/// 1. 整体替换选了素材，且素材文件已落地 → 那条素材
/// 2. 这个单元在原片上有对应的一段 → 原片的那一段
/// 3. 否则 null——这一段真的没东西可放（垫黑场并点名，不许静默跳过）
///
/// 第 1 条**取不到文件时继续往下走**，不是直接判没有：素材还在下载时
/// 预览照旧放原片，这是既有行为。
///
/// [wholeCandidateId] 是「这一条变体在这个单元上用哪张底片」。导出时
/// 同一个单元在不同变体里用不同候选，由调用方指定；不给就用 ★ 预览那条。
///
/// [durationOf] 探素材时长。探不出来时退回坑位时长——**不编造一个数**。
UnitBase? baseOf({
  required SemanticUnit unit,
  required UnitReplacement replacement,
  required String? Function(int candidateId) pathOf,
  String? sourcePath,
  int? wholeCandidateId,
  int? Function(int candidateId)? durationOf,
}) {
  final choice = baseChoiceOf(
    unit: unit,
    replacement: replacement,
    wholeCandidateId: wholeCandidateId,
    hasOriginal: sourcePath != null,
  );
  switch (choice) {
    case MaterialBase(:final candidateId):
      final path = pathOf(candidateId);
      if (path != null) {
        // 素材整条用上，从头到尾——「时长跟候选走」是整体替换的既有规则。
        //
        // 这里不理会 `wholeTrimStarts`：那个字段今天只有剪映草稿导出在用，
        // 成片渲染（`ExportCommands.wholeReplacementVideo`）根本没有 trim
        // 参数。照搬这个既有的不一致，留给阶段二一并收拾
        return UnitBase(
          path: path,
          startMs: 0,
          endMs: durationOf?.call(candidateId) ?? unit.durationMs,
          candidateId: candidateId,
        );
      }
      // **选了素材但文件还没落地**：退回原片，这是既有行为——素材还在下载
      // 时预览照旧放原片，不是黑屏。原片也没有就真的没东西可放
      return unit.hasSource && sourcePath != null
          ? UnitBase(path: sourcePath, startMs: unit.startMs, endMs: unit.endMs)
          : null;
    case OriginalBase(:final startMs, :final endMs):
      return UnitBase(path: sourcePath!, startMs: startMs, endMs: endMs);
    case NoBase():
      return null;
  }
}

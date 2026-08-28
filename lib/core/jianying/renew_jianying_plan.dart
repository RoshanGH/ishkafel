import '../analysis/providers.dart';
import '../audio/bgm_plan.dart';
import '../models/semantic_unit.dart';
import '../models/shot.dart';
import '../replacement/replacement_plan.dart';
import 'jianying_plan.dart';

/// 把替换裂变的方案摊成剪映的多轨工程。
///
/// **一个任务一份工程，所有候选都摆进去**——不是导 100 条草稿。同一个时间
/// 位置上挑了几条候选就有几条轨，上层盖下层；人在剪映里把上面那条关掉，
/// 下面那条就露出来。等于把「挑哪一条」这一步搬进剪映，边看边定。
///
/// 轨道从下往上：
///
/// 1. **分子轨**——原片按台词语义单元切开，铺满全片
/// 2. **原子轨**——原片按视觉镜头切开（没有镜头的单元就整段摆着）
/// 3. **候选轨若干**——第 N 条轨放各个位置的第 N 个候选，缺的位置就空着
///
/// 两条原片轨内容相同、切分粒度不同：进了剪映能看见两层结构的边界，
/// 想按分子调就在分子轨上调，想按镜头调就在原子轨上调。
JianyingPlan buildRenewJianyingPlan({
  required List<SemanticUnit> units,
  required List<UnitReplacement> replacements,
  required String sourcePath,
  required int sourceTotalMs,

  /// 候选素材在本地的路径；null = 还没落地，直接抛
  required String? Function(int candidateId) materialOf,

  /// 候选素材本身多长（毫秒）。用来算塞进坑位要多少倍速
  required int Function(int candidateId) materialDurationOf,

  /// 台词（ASR 句子）。进剪映摆成文本轨——做成图就锁死了，
  /// 而人进剪映本来就是为了改东西
  List<AsrSentence> sentences = const [],

  /// 配乐方案。每段铺它选的第一首：多首是导出多条时轮换用的，
  /// 一份工程里摆一条轨，要换在剪映里换
  BgmPlan bgm = BgmPlan.empty,
  String? Function(int materialId)? bgmPathOf,
}) {
  if (units.isEmpty) return const JianyingPlan();

  // 1. 分子轨：原片按单元切开
  final moleculeTrack = [
    for (final u in units)
      JyVideoSegment(
        path: sourcePath,
        atMs: u.startMs,
        durationMs: u.endMs - u.startMs,
        sourceStartMs: u.startMs,
        sourceDurationMs: u.endMs - u.startMs,
        speed: 1.0,
        // 原片的声音跟着原片画面走，替换片的声音跟着替换片走——
        // 都不拆成独立音轨，人在剪映里按段调
        volume: 1.0,
        sourceTotalMs: sourceTotalMs,
      ),
  ];

  // 2. 原子轨：原片按镜头切开。没切出镜头的单元整段摆着——
  //    留空的话那一段在原子轨上是个洞，人以为素材丢了
  final atomTrack = <JyVideoSegment>[];
  for (final u in units) {
    final shots = u.shots;
    if (shots.isEmpty) {
      atomTrack.add(JyVideoSegment(
        path: sourcePath,
        atMs: u.startMs,
        durationMs: u.endMs - u.startMs,
        sourceStartMs: u.startMs,
        sourceDurationMs: u.endMs - u.startMs,
        speed: 1.0,
        volume: 1.0,
        sourceTotalMs: sourceTotalMs,
      ));
      continue;
    }
    for (final s in shots) {
      atomTrack.add(JyVideoSegment(
        path: sourcePath,
        atMs: s.startMs,
        durationMs: s.endMs - s.startMs,
        sourceStartMs: s.startMs,
        sourceDurationMs: s.endMs - s.startMs,
        speed: 1.0,
        volume: 1.0,
        sourceTotalMs: sourceTotalMs,
      ));
    }
  }

  // 3. 候选轨：先把「哪个坑位、第几候选、哪条素材」摊平，再按第几候选分轨
  final picks = <_Pick>[];
  for (final u in units) {
    final r = u.index < replacements.length ? replacements[u.index] : null;
    if (r == null) continue;
    switch (r.mode) {
      case ReplacementMode.whole:
        _collect(picks, r.wholeCandidateIds, u.startMs, u.endMs);
      case ReplacementMode.perShot:
        for (final entry in r.shotCandidateIds.entries) {
          final shot = _shotAt(u.shots, entry.key);
          if (shot == null) continue;
          _collect(picks, entry.value, shot.startMs, shot.endMs);
        }
      case ReplacementMode.keepOriginal:
        break;
    }
  }

  final layers = picks.isEmpty
      ? 0
      : picks.map((p) => p.rank).reduce((a, b) => a > b ? a : b) + 1;
  final candidateTracks = <List<JyVideoSegment>>[];
  for (var rank = 0; rank < layers; rank++) {
    final segs = <JyVideoSegment>[];
    for (final p in picks.where((p) => p.rank == rank)) {
      final path = materialOf(p.candidateId);
      if (path == null) {
        throw JianyingPlanException(
            '素材 ${p.candidateId} 还没存到本地，写不进剪映工程。'
            '等它下完再导，或在「替换素材」的已选托盘上点 ↻ 重试');
      }
      final slot = p.endMs - p.startMs;
      final total = materialDurationOf(p.candidateId);
      // 素材比坑位长就加速、短就放慢——和成片导出同一个口径，
      // 人在剪映里看到的倍率就是 ishkafel 里算出来的那个
      final speed = total <= 0 ? 1.0 : total / slot;
      segs.add(JyVideoSegment(
        path: path,
        atMs: p.startMs,
        durationMs: slot,
        sourceStartMs: 0,
        sourceDurationMs: total <= 0 ? slot : total,
        speed: speed,
        volume: 1.0,
        sourceTotalMs: total <= 0 ? slot : total,
      ));
    }
    segs.sort((a, b) => a.atMs.compareTo(b.atMs));
    candidateTracks.add(segs);
  }

  // 4. 配乐轨：区间按单元下标记，换算成毫秒
  final bgmSegs = <JyAudioSegment>[];
  for (final seg in bgm.segments) {
    final material = seg.materials.firstOrNull;
    final path = material == null ? null : bgmPathOf?.call(material.id);
    if (material == null || path == null) continue;
    final from = _unitAt(units, seg.startUnit)?.startMs;
    final to = _unitAt(units, seg.endUnit)?.endMs;
    if (from == null || to == null || to <= from) continue;
    bgmSegs.add(JyAudioSegment(
      path: path,
      atMs: from,
      durationMs: to - from,
      sourceStartMs: 0,
      volume: 1.0,
      sourceTotalMs: material.durationMs,
    ));
  }

  return JianyingPlan(
    text: [
      for (final s in sentences)
        if (s.text.trim().isNotEmpty)
          JyTextSegment(
            text: s.text.trim(),
            atMs: s.startMs,
            durationMs: s.endMs - s.startMs,
          ),
    ],
    bgm: bgmSegs,
    videoTracks: [
      moleculeTrack,
      atomTrack,
      ...candidateTracks.where((t) => t.isNotEmpty),
    ],
  );
}

void _collect(List<_Pick> out, List<int> ids, int startMs, int endMs) {
  for (var i = 0; i < ids.length; i++) {
    out.add(_Pick(
        candidateId: ids[i], rank: i, startMs: startMs, endMs: endMs));
  }
}

SemanticUnit? _unitAt(List<SemanticUnit> units, int index) {
  for (final u in units) {
    if (u.index == index) return u;
  }
  return null;
}

/// 镜头没有自己的编号，位置就是编号（与 replacements 里的 key 一致）
Shot? _shotAt(List<Shot> shots, int index) =>
    index >= 0 && index < shots.length ? shots[index] : null;

/// 一个坑位上的第 [rank] 个候选
class _Pick {
  final int candidateId;
  final int rank;
  final int startMs;
  final int endMs;

  const _Pick({
    required this.candidateId,
    required this.rank,
    required this.startMs,
    required this.endMs,
  });
}

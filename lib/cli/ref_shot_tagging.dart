import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ai/tag_dimension.dart';
import '../core/ai/taggers.dart';
import '../core/ffmpeg/process_runner.dart';
import '../core/log/app_log.dart';
import '../core/script/script_doc.dart';

/// 给参考片的某一镜打标：**画面描述 + 标签 + 首帧图**。
///
/// 为什么必须有这一步：`script extract` 只出台词与切点，参考镜的
/// `description`/`tags`/`framePath` 全是空的。而挑镜头的三条路全都依赖它们：
///
/// - 手册第一位的依据「先看 framePath 那张图」→ 没有图
/// - `--by tags`（参考镜打过标时的默认路子）→ 没有标签
/// - 缺省的 `--by content`（照参考镜的画面描述搜）→ 没有描述
///
/// 界面上这一步是「点选那一镜时才打」（打标花钱，不整片预打），
/// CLI 之前完全没有入口——验收 Agent 只能自己 ffmpeg 抽帧、肉眼看图、
/// 手写关键词，中间多了一层有损转译，写偏了就搜回一堆别的品牌。
///
/// **三帧而不是一帧**：单帧只看得到一个静止姿态，判不出镜头里在发生什么
/// （与界面同一条规矩，见 ShotTagger.understand）。
Future<RefShotMeta?> tagRefShot({
  required ScriptLine line,
  required String videoPath,
  required int segIndex,
  required Directory workDir,
  required ShotTagger tagger,
  required List<TagDimension> vocabulary,
  String? constraint,
  ProcessRunner? run,
}) async {
  final ref = line.reference;
  if (ref == null) return null;
  final segs = ref.segments;
  if (segIndex < 0 || segIndex >= segs.length) return null;
  final (segStart, segEnd) = segs[segIndex];
  final exec = run ?? const ResolvingProcessRunner().call;

  try {
    final dir = Directory(p.join(workDir.path, 'tag_${line.id}_$segIndex'));
    await dir.create(recursive: true);
    final frames = <List<int>>[];
    String? firstFrame;
    for (final (i, at) in [
      (0, segStart + 120),
      (1, (segStart + segEnd) ~/ 2),
      (2, segEnd - 120),
    ]) {
      final out = p.join(dir.path, 'f$i.jpg');
      final r = await exec('ffmpeg', [
        '-y', '-v', 'error',
        '-ss', (at / 1000).toStringAsFixed(3),
        '-i', videoPath,
        '-frames:v', '1',
        '-vf', 'scale=-2:480',
        out,
      ]);
      if (r.exitCode == 0 && File(out).existsSync()) {
        frames.add(File(out).readAsBytesSync());
        // 中间那一帧当代表图：两端常踩在转场上
        firstFrame ??= out;
      }
    }
    if (frames.isEmpty) return null;
    final understanding = await tagger.understand(
      frames: frames,
      dimensions: vocabulary,
      constraint: constraint,
    );
    return RefShotMeta(
      startMs: segStart,
      description: understanding.description ?? '',
      tags: understanding.tags,
      framePath: firstFrame,
    );
  } catch (e) {
    AppLog.warn('参考镜打标失败（line=${line.id} seg=$segIndex）：$e');
    return null;
  }
}

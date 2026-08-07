import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../ai/ark_chat_client.dart';
import '../ffmpeg/process_runner.dart';
import '../log/app_log.dart';
import 'shot_boundary_detector.dart';

/// 复核一个灰区切点的结论
enum BoundaryVerdict {
  /// 确实是两个镜头的交界，保留这一刀
  cut,

  /// 同一个镜头内部（多半只是画面里动得厉害），撤掉这一刀
  same,

  /// 没看成（额度用完/调用失败/看不准）——按保留处理，见 [BoundaryReviewer]
  unknown,
}

/// 灰区切点的画面复核。
///
/// 数值判据到这一步已经用尽：实测最像切换的一个**误检**（手在冰箱前快速
/// 移动）直方图距离 0.374，而最弱的**真实切换** 0.490——中间这段没有任何
/// 数值能可靠区分，只能看一眼画面。
///
/// 两条硬性约束：
/// - **只看灰区**，确认的切点不送检。否则一条素材要几十次视觉推理，
///   分析时间和 API 额度都不划算。
/// - **看不成就保留**。漏切一刀用户得自己在时间线上找位置补刀，多切一刀
///   点一下合并就行——代价不对称，兜底方向只能偏向保留。
class BoundaryReviewer {
  final ArkChatClient chat;
  final ProcessRunner run;
  final Directory workDir;

  /// 复核用的模型。见 [reviewOne] 里的说明：这是全片最简单的一问，
  /// 用最小的模型，延迟差 5~7 倍。
  static const String model = 'doubao-seed-2-0-mini-260428';

  /// 一条素材最多送检多少个切点。超出的一律保留，不是丢弃。
///
/// **为什么这一步换不成纯算法**（2026-08-05 拿两条真实素材验过，别再试了）：
/// 灰区候选里「真切换」与「剧烈运动」在**画面变化量**这个维度上完全重叠——
/// 视频一的 23 个灰区候选中 10 真 13 假，真的那组比值中位数 4.94、假的 4.63，
/// 范围也几乎一样。取任何一条界线：保住全部真切点就只能挡掉 13 个假的里的 1 个。
///
/// 换滑动平均、方差、邻域比值都一样——它们都是同一个信号的不同算法。要分开
/// 这两类，必须看**画面内容**（前后拍的是不是同一个东西），那正是这一步在做的事。
///
/// 也试过用关键帧位置代替：这类素材是平台转码产物，GOP 固定 0.93 秒，
/// I 帧位置与镜头切换毫无关系。
  final int maxReviews;

  const BoundaryReviewer({
    required this.chat,
    required this.workDir,
    this.run = systemProcessRunner,
    this.maxReviews = 24,
  });

  static const String prompt = '这张图是同一条视频里前后相邻的两帧，左边在前、右边在后。'
      '请判断它们属于同一个连续镜头，还是两个不同镜头的交界。\n'
      '判断依据：镜头交界意味着机位、景别或场景发生了切换；'
      '而同一个镜头里人手移动、物体进出画面、轻微推拉摇都**不算**交界。\n'
      '只回答一个词：交界 或 同一镜头。';

  /// 只挑出需要送检的那些（按把握程度从低到高，最没把握的优先看）
  List<ShotBoundaryCandidate> pick(List<ShotBoundaryCandidate> all) {
    final uncertain = [for (final c in all) if (!c.isConfirmed) c]
      ..sort((a, b) => a.histDistance.compareTo(b.histDistance));
    return List.unmodifiable(uncertain.take(maxReviews));
  }

  /// 抽出切点前后两帧并排拼成一张图
  static List<String> stackArgs({
    required String videoPath,
    required double beforeSeconds,
    required double atSeconds,
    required String outPath,
  }) =>
      [
        '-y',
        '-ss', beforeSeconds.toStringAsFixed(3), '-i', videoPath,
        '-ss', atSeconds.toStringAsFixed(3), '-i', videoPath,
        '-filter_complex',
        '[0:v]scale=320:-1[a];[1:v]scale=320:-1[b];[a][b]hstack=inputs=2',
        '-frames:v', '1',
        outPath,
      ];

  /// 把回答归一成结论。模型偶尔会多说两句，用包含判断而不是全等。
  static BoundaryVerdict parseVerdict(String reply) {
    final text = reply.trim();
    if (text.contains('同一镜头') || text.contains('同一个镜头')) {
      return BoundaryVerdict.same;
    }
    if (text.contains('交界')) return BoundaryVerdict.cut;
    return BoundaryVerdict.unknown;
  }

  static Future<void> _discard(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      AppLog.warn('清理切点复核图失败 ${file.path}：$e');
    }
  }

  Future<BoundaryVerdict> reviewOne({
    required String videoPath,
    required ShotBoundaryCandidate candidate,
    required double fps,
    required String taskId,
  }) async {
    final at = candidate.ms / 1000.0;
    final before = at - (fps > 0 ? 1 / fps : 0.033);
    final outPath = p.join(workDir.path, '${taskId}_rev${candidate.ms}.jpg');
    try {
      final result = await run(
          'ffmpeg',
          stackArgs(
              videoPath: videoPath,
              beforeSeconds: before < 0 ? 0 : before,
              atSeconds: at,
              outPath: outPath));
      if (result.exitCode != 0) return BoundaryVerdict.unknown;
      final bytes = await File(outPath).readAsBytes();
      // 复核图只喂给模型判这一次，判完就没人看了（打标痕迹里存的是打标帧，
      // 不是复核帧）。一条 96 秒的片子会攒下上百张
      unawaited(_discard(File(outPath)));
      // 判断题，不是创作题：不给 0 的话同一个切点两次能给出不同结论，
      // 而视觉镜头层本该是「程序切的、可复现的」。
      //
      // 用 mini 而不是默认的 lite：这是全片最简单的一问（两帧是不是同一个
      // 镜头），实测同一张真实复核图 lite 要 6~12 秒、mini 只要 1.2~1.7 秒，
      // 答案一模一样。**这一步的时间下限就是单次调用的延迟**——18 个候选
      // 全并发，等的是最慢那一个，并发再高也压不到延迟以下。
      final reply = await chat.chatVision(
          prompt: prompt,
          jpegBytes: bytes,
          maxTokens: 32,
          temperature: 0,
          model: model);
      return parseVerdict(reply);
    } catch (e) {
      AppLog.warn('切点 ${candidate.ms}ms 画面复核失败（按保留处理）：$e');
      return BoundaryVerdict.unknown;
    }
  }
}

/// 按复核结论过滤候选切点。
///
/// [verdicts] 里没有的、或结论是 unknown 的，一律保留——见 [BoundaryReviewer]
/// 关于代价不对称的说明。
List<ShotBoundaryCandidate> applyVerdicts(
  List<ShotBoundaryCandidate> candidates,
  Map<int, BoundaryVerdict> verdicts,
) =>
    List.unmodifiable([
      for (final c in candidates)
        if (verdicts[c.ms] != BoundaryVerdict.same) c,
    ]);

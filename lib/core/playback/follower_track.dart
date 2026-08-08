import 'package:flutter/foundation.dart';

import 'track_plan.dart';

/// 一条**只出声的跟随轨**：自己不管时间轴，主时钟说到哪就跟到哪。
///
/// 抽成接口是为了让下面那套「什么时候该 load / seek / 校正」的判断能脱离
/// media_kit 单测——多轨同步是这套架构唯一的技术风险，不能只靠真机手感。
abstract class FollowerTrack {
  /// 换源。[edl] 为 null 表示这一轨这次没东西可播
  Future<void> load(String? edl);

  Future<void> play();
  Future<void> pause();
  Future<void> seekMs(int ms);

  /// 0.0 ~ 1.0
  Future<void> setVolume(double volume);

  /// 当前位置（毫秒）。还没加载时返回 0
  int get positionMs;

  Future<void> dispose();
}

/// 主时钟与跟随轨之间容许多大偏差。
///
/// 真机实测：三个播放器实例同时跑 10 秒，偏差在 ±70ms 以内且**不累积**
/// （在正负之间抖，说明主要是分三次读位置的时间差，不是真漂移）。阈值取
/// 150ms——比抖动幅度留出一倍余量，否则会被抖动骗得反复 seek，而每次 seek
/// 都是一次可闻的接缝。
const int syncToleranceMs = 150;

/// 该不该纠偏。[follower] 为 null（还没加载）时不纠
bool needsResync({required int masterMs, required int? followerMs}) {
  if (followerMs == null) return false;
  return (followerMs - masterMs).abs() > syncToleranceMs;
}

/// 这一刻配乐轨应该是什么样。[source] 为 null 表示这一刻不该出声。
@immutable
class BgmCue {
  final String? source;

  /// 该播这首曲子的哪一刻（已按「不够长就循环」取过模）
  final int inMs;
  final double volume;

  const BgmCue({this.source, this.inMs = 0, this.volume = 1});

  static const silent = BgmCue();

  @override
  bool operator ==(Object other) =>
      other is BgmCue &&
      other.source == source &&
      other.inMs == inMs &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(source, inMs, volume);
}

/// 成片走到 [masterMs] 这一刻，配乐轨该播什么。
///
/// 段与段不重叠，所以最多命中一段。没命中就静音——这就是「太长就播到段尾停」：
/// 走出这一段的范围，配乐自然停了。
BgmCue bgmCueAt(TrackPlan plan, int masterMs) {
  final segment = plan.bgmAt(masterMs);
  if (segment == null) return BgmCue.silent;
  return BgmCue(
    source: segment.clip.source,
    inMs: segment.sourceMsAt(masterMs),
    volume: segment.volume,
  );
}

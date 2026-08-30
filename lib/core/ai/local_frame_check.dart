import 'dart:io';

import 'package:path/path.dart' as p;

import '../ffmpeg/thumbnail_service.dart';
import '../log/app_log.dart';
import 'frame_check.dart';

/// 从**本地视频**里抽几帧，做一次画面自查（烧字 + 产品露出品牌）。
///
/// 界面走的是素材首帧图（挑素材时本来就下到本地了），命令行这条路上没有
/// 那张图、但素材本体已经下下来了——抽帧就是。两条路最后汇到同一个
/// [FrameChecker]，说法和判断不会走样。
///
/// **抽头中尾三帧而不是一帧**：一帧判不出一条素材里有没有产品露出。
/// 真机上栽过——素材 114801 首帧是一排 Dettol 滴露瓶、尾帧右上角也有一瓶，
/// 唯独中段那一帧是微波炉内部什么都没有，而我们只送了中段，
/// 于是这条明显是滴露的素材被记成「无产品露出」。
///
/// 三帧**送进同一次调用**，不是跑三次：token 约 2.9 倍，调用次数不变。
class LocalVideoFrameChecker {
  final FrameChecker checker;
  final ThumbnailService thumbnails;

  /// 抽出来的帧放哪儿。用完就删——这是纯中间产物，不该在盘上留过夜
  final Directory workDir;

  const LocalVideoFrameChecker({
    required this.checker,
    required this.thumbnails,
    required this.workDir,
  });

  /// [videoPath] 是本地素材；[durationMs] 用来定位头中尾，不知道时按一个
  /// 保守跨度抽（**不退回单帧**——退回单帧就是把漏报的老路再走一遍）。
  Future<FrameCheck> check(int materialId, String videoPath,
      {int? durationMs}) async {
    workDir.createSync(recursive: true);
    final frames = <String>[];
    try {
      for (final at in _sampleSeconds(durationMs)) {
        final out = p.join(workDir.path, 'fc_${materialId}_$at.jpg');
        try {
          await thumbnails.extractCover(
            videoPath: videoPath,
            outPath: out,
            atSeconds: at,
            // 看字要比看「画面是什么」清楚一档：512 高上一行小字会糊掉
            height: 720,
          );
          frames.add(out);
        } catch (e) {
          // 某一帧抽不出来（跨过了结尾、这一段坏了）不该让整条素材放弃——
          // 剩下的帧照样能看出烧字和品牌。一帧都抽不出来时下面会抛
          AppLog.warn('素材 $materialId 的第 ${at}s 那一帧抽不出来（$e），'
              '用剩下的帧继续看');
        }
      }
      if (frames.isEmpty) {
        throw StateError('素材 $materialId 一帧都抽不出来，看不了画面');
      }
      return await checker.check(frames);
    } finally {
      for (final f in frames) {
        final file = File(f);
        if (!file.existsSync()) continue;
        try {
          file.deleteSync();
        } catch (_) {
          // 删不掉不影响结果，下次覆盖
        }
      }
    }
  }

  /// 头中尾三个采样点（秒）。
  ///
  /// 开头不取第 0 秒、结尾不取最后一刻：那两处常是黑帧或转场，什么都看不出来。
  /// 素材很短时几个点会撞在一起，去重后可能只剩一两帧——那是这条素材本身
  /// 就没几秒，不是我们偷懒。
  static List<double> _sampleSeconds(int? durationMs) {
    // 时长不知道时按 10 秒估：素材库里的分镜普遍 4~30 秒，取一个偏短的值，
    // 抽过了尾巴那一帧会失败，而失败是允许的（上面会跳过）
    final total = (durationMs ?? 10000) / 1000;
    final points = [total * 0.1, total * 0.5, total * 0.9];
    final seen = <String>{};
    return [
      for (final t in points)
        if (seen.add(t.toStringAsFixed(1))) double.parse(t.toStringAsFixed(1)),
    ];
  }
}

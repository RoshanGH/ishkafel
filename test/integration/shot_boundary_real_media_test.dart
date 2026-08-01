@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/frame_signal_extractor.dart';
import 'package:ishkafel/core/analysis/shot_boundary_detector.dart';
import 'package:ishkafel/core/analysis/shot_boundary_finder.dart';

/// 真实素材端到端验证：跑真 ffmpeg，不走任何替身。
///
/// 单测只能证明逻辑自洽——「阈值定得对不对」「两份 ffmpeg 产物对不对得上」
/// 这类事只有真跑一遍才知道。素材不在时整组跳过，不让 CI 因环境而红。
///
/// 跑法：flutter test test/integration --tags integration
const _fixtures = <String, ({int minCuts, int maxCuts})>{
  '/Users/menggang/Documents/滴露视频/JC_滴露_植源喷雾_XCT_SQ1&YY6_CH_千川直播_M66028501_0427.mp4':
      (minCuts: 40, maxCuts: 110),
  '/Users/menggang/Documents/滴露视频/JC_滴露_植源喷雾_ZJD_YY6_XXD_千川直播_M65787602_0427.mp4':
      (minCuts: 30, maxCuts: 90),
};

void main() {
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('shot_real_'));
  tearDown(() => work.deleteSync(recursive: true));

  for (final entry in _fixtures.entries) {
    final path = entry.key;
    final name = path.split('/').last.substring(0, 20);
    final bounds = entry.value;

    test('真实素材 $name：切点数量合理且严格递增', () async {
      if (!File(path).existsSync()) {
        markTestSkipped('素材不存在：$path');
        return;
      }

      final finder = ShotBoundaryFinder(
        extractor: FrameSignalExtractor(workDir: work),
        // 不接复核：这组测试要验的是**算法**，不该依赖云端凭据与额度
      );

      final cuts = await finder.find(
          videoPath: path, taskId: 'real', fps: 30);

      expect(cuts.length, inInclusiveRange(bounds.minCuts, bounds.maxCuts),
          reason: '切点数量落到区间外，说明阈值或信号采集出了问题。'
              '实测基线：XCT 77 个、ZJD 58 个');
      for (var i = 1; i < cuts.length; i++) {
        expect(cuts[i], greaterThan(cuts[i - 1]), reason: '切点必须严格递增');
      }
      expect(cuts.first, greaterThanOrEqualTo(0));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('真实素材 $name：相邻切点不短于最短镜头时长', () async {
      if (!File(path).existsSync()) {
        markTestSkipped('素材不存在：$path');
        return;
      }

      final minShotMs = const BoundaryThresholds().minShotMs;
      final cuts = await ShotBoundaryFinder(
              extractor: FrameSignalExtractor(workDir: work))
          .find(videoPath: path, taskId: 'real2', fps: 30);

      for (var i = 1; i < cuts.length; i++) {
        expect(cuts[i] - cuts[i - 1], greaterThanOrEqualTo(minShotMs),
            reason: '几帧长的碎片镜头没有产品意义，只会让用户多点几次合并');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('真实素材 $name：人工核对过的两个真实切换都被检出', () async {
      if (!path.contains('XCT') || !File(path).existsSync()) {
        markTestSkipped('这两个样本标注自 XCT');
        return;
      }

      final cuts = await ShotBoundaryFinder(
              extractor: FrameSignalExtractor(workDir: work))
          .find(videoPath: path, taskId: 'real3', fps: 30);

      // 抽帧目视确认过：手持喷瓶特写→台面三瓶、气球摆台→厨房全景
      for (final expected in [7467, 30267]) {
        final hit = cuts.any((c) => (c - expected).abs() <= 100);
        expect(hit, isTrue,
            reason: '${expected}ms 是人工核对过的真实镜头切换，'
                '旧的固定阈值 0.35 正是漏掉了它（scene 只有 0.339）');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}

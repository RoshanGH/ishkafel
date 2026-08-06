import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/analysis/batch_frame_plan.dart';

void main() {
  group('把全片要的帧排成一次 ffmpeg', () {
    test('毫秒按帧率换成帧号，升序去重', () {
      final plan = BatchFramePlan.of(requestedMs: [2000, 100, 1000], fps: 30);

      expect(plan.frameNumbers, [3, 30, 60]);
    });

    test('落在同一帧的多个请求合并成一次抽，但各自都能取到图', () {
      // 30fps 下 1000ms 与 1010ms 是同一帧
      final plan = BatchFramePlan.of(requestedMs: [1000, 1010], fps: 30);

      expect(plan.frameNumbers, [30],
          reason: '重复抽同一帧白花时间，而 ffmpeg 也只会吐一张，'
              '不合并的话后面的编号会整体错位');
      expect(plan.outputIndexOf(1000), 1);
      expect(plan.outputIndexOf(1010), 1);
    });

    test('输出编号按帧号升序给，和 ffmpeg 吐图的顺序一致', () {
      final plan = BatchFramePlan.of(requestedMs: [2000, 100, 1000], fps: 30);

      expect(plan.outputIndexOf(100), 1);
      expect(plan.outputIndexOf(1000), 2);
      expect(plan.outputIndexOf(2000), 3);
    });

    test('select 表达式逐帧号列出，逗号转义', () {
      final plan = BatchFramePlan.of(requestedMs: [0, 1000], fps: 30);

      expect(plan.selectExpression, r'eq(n\,0)+eq(n\,30)');
    });

    test('帧率不是整数也照算——29.97 是常见的现实', () {
      final plan = BatchFramePlan.of(requestedMs: [1000], fps: 29.97);

      expect(plan.frameNumbers, [30]);
    });

    test('空请求给空计划，不去跑一次没有意义的 ffmpeg', () {
      expect(BatchFramePlan.of(requestedMs: const [], fps: 30).isEmpty, isTrue);
    });

    test('帧率不可信时不装作能算——宁可退回逐帧抽', () {
      expect(BatchFramePlan.of(requestedMs: [1000], fps: 0).isEmpty, isTrue,
          reason: 'fps 为 0 时帧号全是 0，153 帧会挤成一张，标签会错到别的镜头上');
      expect(BatchFramePlan.of(requestedMs: [1000], fps: -1).isEmpty, isTrue);
    });
  });

  group('该不该走批量：拿两边的实测代价比，而不是定个数字', () {
    // 实测（96 秒素材、8 核、缩到 512）：批量一次解码 9.1s；
    // 逐帧定位 153 帧并发 8 用 16.4s，合每帧 0.107s
    const durationMs = 96233;

    test('全片打标这种量级走批量——一次解码好过上百次定位', () {
      expect(
          BatchFramePlan.worthBatching(
              frameCount: 153, videoDurationMs: durationMs),
          isTrue);
    });

    test('改完一个镜头重新打标时不走——为三帧解码整条片子是亏的', () {
      expect(
          BatchFramePlan.worthBatching(
              frameCount: 3, videoDurationMs: durationMs),
          isFalse);
    });

    test('临界点随片长走：片子越长，一次解码越贵，越要多帧才划算', () {
      // 96 秒片子的交叉点在 85 帧左右
      expect(
          BatchFramePlan.worthBatching(
              frameCount: 90, videoDurationMs: durationMs),
          isTrue);
      expect(
          BatchFramePlan.worthBatching(
              frameCount: 80, videoDurationMs: durationMs),
          isFalse);
      // 同样 90 帧，放到十分钟的片子上就不划算了
      expect(
          BatchFramePlan.worthBatching(
              frameCount: 90, videoDurationMs: 600000),
          isFalse);
    });

    test('片长未知时不赌——退回逐帧，慢一点但不会更糟', () {
      expect(
          BatchFramePlan.worthBatching(frameCount: 153, videoDurationMs: 0),
          isFalse);
    });
  });
}

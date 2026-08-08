import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 镜头替换段在**原片时间轴**上的位置。
///
/// 这里钉的是一个真实故障（任务 hl30v3y45q，U2 的 S6）：变速切片段建出来时
/// 没带原片坐标，`sourceStartMs` 默认取了 `inMs`——而切片是从头播的，inMs=0。
/// 于是这一段声称自己对应「原片的 0~2.9 秒」，同时把它真正占着的原片区间
/// 24.6~27.5 秒从映射表里挖成一个空洞。
///
/// 后果是换轨那一刻（切片刚渲染好、点一下 ★、改配乐）要按逻辑位置回到原处：
/// `toComposedMs(原片25秒)` 谁都不命中，兜底一路跳到片尾。用户看到的是
/// 「播放指针突然快速往后走，后面几秒像是被快进了」，声音也跟着被拽过去
/// （口播是跟随轨，主时钟跳了它就被纠偏跟上）。
void main() {
  // 真实数据：U1 15.3s（整体换成 16.3s 的候选）、U2 八个镜头、S6 是 24.6~27.467
  final units = [
    SemanticUnit(
      index: 0,
      startMs: 0,
      endMs: 15300,
      transcript: '',
      shots: const [Shot(startMs: 0, endMs: 15300)],
    ),
    SemanticUnit(
      index: 1,
      startMs: 15300,
      endMs: 30267,
      transcript: '',
      shots: const [
        Shot(startMs: 15300, endMs: 16200),
        Shot(startMs: 16200, endMs: 18933),
        Shot(startMs: 18933, endMs: 19967),
        Shot(startMs: 19967, endMs: 23567),
        Shot(startMs: 23567, endMs: 24600),
        Shot(startMs: 24600, endMs: 27467), // S6：被替换的这一个
        Shot(startMs: 27467, endMs: 28600),
        Shot(startMs: 28600, endMs: 30267),
      ],
    ),
    SemanticUnit(
        index: 2, startMs: 30267, endMs: 52733, transcript: '', shots: const []),
  ];

  TrackPlan planWith({bool fitted = true, bool whole = true}) =>
      TrackPlanBuilder.build(
        sourcePath: '/SRC.mp4',
        units: units,
        replacements: [
          whole
              ? UnitReplacement.whole(const [114799], previewId: 114799)
              : UnitReplacement.keepOriginal(),
          UnitReplacement.perShot(const {
            5: [116719]
          }, previewIds: const {5: 116719}),
          UnitReplacement.keepOriginal(),
        ],
        materials: const {
          114799: LocalMaterial(path: '/WHOLE.mp4', durationMs: 16300),
          116719: LocalMaterial(path: '/CAND.mp4', durationMs: 5503),
        },
        speedFitted: fitted ? const {'1/5': '/FIT_S6.mp4'} : const {},
      );

  TrackSegment fitSegmentOf(TrackPlan plan) =>
      plan.video.firstWhere((s) => s.source == '/FIT_S6.mp4');

  group('变速切片段要认领它占着的那段原片', () {
    test('原片坐标是这个镜头的坑位，不是 0', () {
      final segment = fitSegmentOf(planWith());
      expect(segment.sourceStartMs, 24600);
      expect(segment.sourceSpanMs, 2867);
      // 切片本身还是从头播
      expect(segment.inMs, 0);
    });

    test('切片正好填满坑位，所以映射是线性的、不是按比例估的', () {
      final segment = fitSegmentOf(planWith());
      expect(segment.sourceMsAt(segment.atMs), 24600);
      expect(segment.sourceMsAt(segment.atMs + 1000), 25600);
      expect(segment.sourceMsAt(segment.endMs - 1), 27466);
    });
  });

  group('原片轴上不能有空洞——空洞会让换轨那一刻跳到片尾', () {
    test('被替换镜头覆盖的每一毫秒都换算得回成片，且落在这一段里', () {
      final plan = planWith();
      final fit = fitSegmentOf(plan);
      for (final sourceMs in [24600, 25000, 26000, 27000, 27466]) {
        final composed = plan.toComposedMs(sourceMs);
        expect(composed, greaterThanOrEqualTo(fit.atMs),
            reason: '原片 $sourceMs 落到了这一段之前');
        expect(composed, lessThan(fit.endMs), reason: '原片 $sourceMs 被甩到了后面');
      }
    });

    test('切片刚渲染好的那一刻，正播在这个镜头里的位置要留在原地', () {
      final before = planWith(fitted: false);
      final after = planWith();
      // 用户正看着 S6 中间（成片 26000）
      const watching = 26000;
      final sourceMs = before.toSourceMs(watching);
      expect(sourceMs, 25000, reason: '还没变速时这一段就是原片本身');
      // 换上切片之后应该还在同一个地方，而不是被扔到片尾
      expect(after.toComposedMs(sourceMs), watching);
      expect(after.toComposedMs(sourceMs), isNot(after.totalMs));
    });

    test('没有整体替换时同样成立——两条路都不能有空洞', () {
      final plan = planWith(whole: false);
      final fit = fitSegmentOf(plan);
      expect(plan.toComposedMs(25000), inInclusiveRange(fit.atMs, fit.endMs));
      expect(plan.toSourceMs(fit.atMs), 24600);
    });

    test('往返换算在整条片子上都对得上', () {
      final plan = planWith();
      for (var composed = 0; composed < plan.totalMs; composed += 250) {
        final back = plan.toComposedMs(plan.toSourceMs(composed));
        expect((back - composed).abs(), lessThanOrEqualTo(1),
            reason: '成片 $composed 转一圈回来变成了 $back');
      }
    });
  });

  group('映射不上时不许悄悄跳到片尾', () {
    test('原片时刻超出所有段落时，落到最近的边界而不是终点', () {
      const plan = TrackPlan(video: [
        TrackSegment(atMs: 0, durationMs: 1000, source: '/A.mp4', inMs: 5000),
      ]);
      // 5000~6000 之外的时刻本来就没有对应的成片位置，但也不该一律甩到片尾
      expect(plan.toComposedMs(4000), 0);
      expect(plan.toComposedMs(9000), 1000);
    });
  });
}

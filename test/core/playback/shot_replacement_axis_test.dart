import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/playback/track_plan.dart';
import 'package:ishkafel/core/playback/track_plan_builder.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 换方案那一刻，人正看的位置要留在原地。
///
/// 这里钉的是一个真实故障（任务 hl30v3y45q，U2 的 S6）：切片刚渲染好、
/// 点一下 ★、改配乐，都会换一次轨；换完要把播放头拉回「他刚才在看的地方」。
/// 原来的锚点是**原片时刻**，而变速切片段没带原片坐标，`sourceStartMs`
/// 默认取了 `inMs`（切片从头播，inMs=0），于是它声称自己对应「原片 0~2.9 秒」，
/// 把真正占着的 24.6~27.5 秒挖成空洞——回不去，兜底一路跳到片尾。用户看到的是
/// 「播放指针突然快速往后走」，声音也跟着被拽过去。
///
/// 一期重构之后锚点改成 **(单元下标, 单元内偏移)**：不再绕原片时刻，
/// 也就不再依赖每一段有没有正确的原片坐标（垫黑场那种段本来就没有）。
/// 见 `docs/2026-09-08-成片时间轴重构-TRD.md` 四、一期。
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

  group('换方案时位置留在原地', () {
    test('切片刚渲染好的那一刻，正播在这个镜头里的位置不动', () {
      final before = planWith(fitted: false);
      final after = planWith();
      // 用户正看着 S6 中间（成片 26000）
      const watching = 26000;

      final anchor = before.anchorAt(watching);

      expect(anchor, isNotNull, reason: '这个位置必须锚得住，锚不住就会跳片尾');
      expect(after.composedAt(anchor!), watching,
          reason: '换上切片之后应该还在同一个地方');
      expect(after.composedAt(anchor), isNot(after.totalMs));
    });

    test('没有整体替换时同样成立', () {
      final before = planWith(whole: false, fitted: false);
      final after = planWith(whole: false);
      const watching = 26000;

      final anchor = before.anchorAt(watching);

      expect(after.composedAt(anchor!), watching);
    });

    test('整条片子上任何一处都锚得住', () {
      final plan = planWith();
      for (var composed = 0; composed < plan.totalMs; composed += 250) {
        final anchor = plan.anchorAt(composed);
        expect(anchor, isNotNull, reason: '成片 $composed 锚不住');
        expect(plan.composedAt(anchor!), composed,
            reason: '成片 $composed 转一圈回来对不上');
      }
    });
  });

  group('锚不住时不许悄悄跳到片尾', () {
    test('单元在新方案里没了：落到片头，而不是终点', () {
      const plan = TrackPlan(video: [
        TrackSegment(atMs: 0, durationMs: 1000, source: '/A.mp4', inMs: 5000),
      ], unitRanges: {0: (0, 1000)});

      expect(plan.composedAt((9, 100, 1000)), 0);
    });

    test('偏移超出这个单元时夹在它里面，不跑到别的段上', () {
      const plan = TrackPlan(video: [
        TrackSegment(atMs: 0, durationMs: 1000, source: '/A.mp4', inMs: 5000),
      ], unitRanges: {0: (0, 1000), 1: (1000, 2000)});

      expect(plan.composedAt((0, 99999, 1000)), 999);
    });
  });
}

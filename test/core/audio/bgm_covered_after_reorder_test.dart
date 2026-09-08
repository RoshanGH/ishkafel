import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/audio_track_builder.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// **「这一段被配乐盖住了没有」只能按单元下标问，不能拿原片时间去比。**
///
/// 2026-09-08 真机，用户原话：「我把 U1 换到其他位置上，或者添加了个台词语义
/// 单元放在了 U1 后面，我发现 U1 的背景音乐就会出问题……把 U1 又放回原来的
/// 位置之后，它的背景音乐就恢复了。」
///
/// 根因：覆盖范围是拿**列表下标**去取 `units[i].startMs/endMs` 拼出来的
/// **原片时间区间**。列表顺序和原片顺序一致时它恰好对，一调序就指到别的段上
/// ——甚至首尾颠倒（起点的原片时间比终点还晚），于是谁都不命中。
///
/// 这个判断决定这一段用**纯人声**还是**原片原声（含背景音）**：判错了，
/// 要么老背景和新配乐一起响，要么背景音凭空消失。人一听就知道不对，
/// 而任何日志里都不会有。
void main() {
  SemanticUnit unit(int index, int a, int b) => SemanticUnit(
        index: index,
        startMs: a,
        endMs: b,
        transcript: 'u$index',
        shots: [Shot(startMs: a, endMs: b)],
      );

  /// 配乐铺在列表的第 0、1 两格上
  BgmPlan bgm() => const BgmPlan([
        BgmSegment(
            startUnit: 0, endUnit: 1, materials: [], fit: BgmFit.loop),
      ]);

  test('顺序正常：前两格被盖住，第三格没有', () {
    final units = [unit(0, 0, 10000), unit(1, 10000, 20000), unit(2, 20000, 30000)];

    final covered = AudioTrackBuilder.bgmCoveredUnits(units, bgm());

    expect(covered, {0, 1});
  });

  test('调过序：盖住的还是**列表**前两格，跟它们取自原片哪一段无关', () {
    // 原片里最后那一段被拖到了最前
    final units = [unit(0, 20000, 30000), unit(1, 0, 10000), unit(2, 10000, 20000)];

    final covered = AudioTrackBuilder.bgmCoveredUnits(units, bgm());

    expect(covered, {0, 1},
        reason: '按原片时间拼区间的话得到 (20000, 10000)——首尾颠倒，'
            '一格都命中不了，被盖住的那两段就会用回含背景音的原声');
  });

  test('手加的单元夹在中间也不乱：它没有原片来源，照样按下标算', () {
    final units = [
      unit(0, 0, 10000),
      const SemanticUnit(
          index: 1,
          startMs: 30000,
          endMs: 40000,
          transcript: '',
          hasSource: false),
      unit(2, 10000, 20000),
    ];

    final covered = AudioTrackBuilder.bgmCoveredUnits(units, bgm());

    expect(covered, {0, 1});
  });

  test('段落指到不存在的单元就跳过', () {
    final units = [unit(0, 0, 10000)];
    const plan = BgmPlan([
      BgmSegment(startUnit: 5, endUnit: 6, materials: [], fit: BgmFit.loop),
    ]);

    expect(AudioTrackBuilder.bgmCoveredUnits(units, plan), isEmpty);
  });

  test('尾端越界夹到最后一格', () {
    final units = [unit(0, 0, 10000), unit(1, 10000, 20000)];
    const plan = BgmPlan([
      BgmSegment(startUnit: 1, endUnit: 9, materials: [], fit: BgmFit.loop),
    ]);

    expect(AudioTrackBuilder.bgmCoveredUnits(units, plan), {1});
  });
}

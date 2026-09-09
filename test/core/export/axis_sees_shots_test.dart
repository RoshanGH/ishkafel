import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/composed_timeline.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// **合并/拆分视觉镜头之后，时间线必须换一条新轴。**
///
/// 2026-09-09 真机，用户原话：「合并为什么还是这样子」——合并完两镜，
/// 镜头轨上那个单元的尾部空出一截，点中的也不是画着的那一格。
///
/// 病灶在 [ComposedTimeline.sameLayoutAs]：界面靠它判断要不要换轴，而它
/// 只比单元的起点、长度、取自原片的哪一段——**从来不看镜头**。合并只动
/// 单元内部，这四样一个都不变，于是判定「轴没变」，时间线继续用着合并
/// 之前那条轴。
///
/// 而镜头在成片上的位置正是从轴里的那份镜头列表算出来的
/// （[composedShotStart]）：新列表 12 个、旧列表 14 个，画的时候拿新列表
/// 的下标去问旧列表——位置全是旧的，末尾那两格的地盘就空在那儿，
/// 点下去命中的也是另一格。
void main() {
  SemanticUnit unitWith(List<Shot> shots) => SemanticUnit(
        uid: 'a',
        index: 0,
        startMs: 0,
        endMs: 3000,
        transcript: '一句台词',
        shots: shots,
      );

  ComposedTimeline axisOf(List<Shot> shots) =>
      ComposedTimeline.of(units: [unitWith(shots)], wholeDurations: const {});

  test('合并两镜之后不是同一条轴', () {
    final before = axisOf([
      Shot(startMs: 0, endMs: 1000),
      Shot(startMs: 1000, endMs: 2000),
      Shot(startMs: 2000, endMs: 3000),
    ]);
    final after = axisOf([
      Shot(startMs: 0, endMs: 2000), // 前两镜合成一格
      Shot(startMs: 2000, endMs: 3000),
    ]);

    expect(before.sameLayoutAs(after), isFalse,
        reason: '判成「一样」的话，时间线会继续用合并之前那条轴——'
            '镜头位置全是旧的，末尾空出一截');
  });

  test('拆分一镜之后不是同一条轴', () {
    final before = axisOf([Shot(startMs: 0, endMs: 3000)]);
    final after = axisOf([
      Shot(startMs: 0, endMs: 1500),
      Shot(startMs: 1500, endMs: 3000),
    ]);

    expect(before.sameLayoutAs(after), isFalse);
  });

  test('只挪了镜头边界（个数不变）也不是同一条轴', () {
    final before = axisOf([
      Shot(startMs: 0, endMs: 1000),
      Shot(startMs: 1000, endMs: 3000),
    ]);
    final after = axisOf([
      Shot(startMs: 0, endMs: 1500),
      Shot(startMs: 1500, endMs: 3000),
    ]);

    expect(before.sameLayoutAs(after), isFalse,
        reason: '拖一下镜头边界，块体就该跟着动');
  });

  test('镜头一模一样时仍然是同一条轴——别每帧都重建', () {
    List<Shot> shots() => [
          Shot(startMs: 0, endMs: 1000),
          Shot(startMs: 1000, endMs: 3000),
        ];

    expect(axisOf(shots()).sameLayoutAs(axisOf(shots())), isTrue,
        reason: '无脑判「变了」的话，播放时每秒重建 30 次整条时间线');
  });
}

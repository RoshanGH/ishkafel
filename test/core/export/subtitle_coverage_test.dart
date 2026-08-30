import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/subtitle_coverage.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 成片里**哪几段会有台词字幕**。
///
/// 两种替换模式在这件事上不一样，而这个差别谁都看不见：
///
/// - **镜头替换**：变速对齐回原坑位，台词字幕重渲上去（原片的字幕烧在
///   被换掉的画面里，不重渲那一段就没字了）
/// - **整体替换**：原样接上、时长随候选，和原坑位对不齐——**没法把按原片
///   时间戳算的字幕直接烧上去，于是那一段成片里没有台词字幕**
///
/// 后果是一条片子里字幕断断续续。验收 Agent 抽了 7 帧都没看到台词字幕，
/// 卡在「不知道是这条任务把字幕关了，还是 whole 模式不烧」——**这个判断
/// 决定了「素材自带烧录字」有多严重**：会烧字幕就是两层字打架、片子废；
/// 不烧就是片子里放着别人的文案，不算废但也不能交。
void main() {
  test('整体替换的单元不会有台词字幕', () {
    final c = subtitleCoverage([
      UnitReplacement.whole(const [11]),
      UnitReplacement.perShot(const {0: [12]}),
    ]);
    expect(c.unitsWithout, [0]);
    expect(c.unitsWith, [1]);
  });

  test('保留原片的单元字幕还在原画面上——不算缺', () {
    final c = subtitleCoverage([UnitReplacement.keepOriginal()]);
    expect(c.unitsWithout, isEmpty);
  });

  test('镜头替换但一个候选都没选：画面没换，字幕还在', () {
    final c = subtitleCoverage([UnitReplacement.perShot(const {})]);
    expect(c.unitsWithout, isEmpty);
  });

  test('整体替换但没选候选：同理，画面没换', () {
    final c = subtitleCoverage([UnitReplacement.whole(const [])]);
    expect(c.unitsWithout, isEmpty);
  });

  test('话术要说清是哪几个单元、以及为什么', () {
    final text = subtitleGapNotice([
      UnitReplacement.whole(const [11]),
      UnitReplacement.keepOriginal(),
      UnitReplacement.whole(const [13]),
    ])!;
    expect(text, contains('U1'));
    expect(text, contains('U3'));
    expect(text, isNot(contains('U2')));
    expect(text, contains('整体替换'));
  });

  test('没有缺口就不啰嗦', () {
    expect(subtitleGapNotice([UnitReplacement.keepOriginal()]), isNull);
  });
}
